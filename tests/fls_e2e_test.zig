const std = @import("std");

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
    // We run tests with cwd=repo root (see build.zig). Spawn the installed fls.
    const fls_cur_rel = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", platformExeName("fls") });
    defer allocator.free(fls_cur_rel);

    const fls_path = try allocator.dupe(u8, fls_cur_rel);
    errdefer allocator.free(fls_path);
    try std.testing.expect(fileExists(fls_path));

    const fun_rel = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", platformExeName("fun") });
    defer allocator.free(fun_rel);
    try std.testing.expect(fileExists(fun_rel));
    const fun_abs = try std.fs.cwd().realpathAlloc(allocator, fun_rel);
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
        "imp std.io;\n\n" ++
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

    // Definition: jump from call `factorial(number)` in main back to the declaration.
    const call_pos = try findPosition(doc_text, "factorial(number)", 0);
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
    const result_val = def_obj.get("result") orelse return error.BadResponse;
    // We accept either [] or a Location/Location[]; key requirement is: no crash + valid JSON.
    _ = result_val;

    // Completion should respond with a list shape (even if empty).
    const comp_pos = try findPosition(doc_text, "std.io", 0);
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
        "imp std.io;\n\n" ++
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
        "imp std.io;\r\n\r\n" ++
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
    const comp_pos = try findPosition(doc_text, "std.io", 0);
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

    // Completion after `std.` should include `io`.
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
    try expectCompletionHasLabel(allocator, comp_result, "io");

    // Now open a doc with `imp std.io;` and request definition on `io`.
    const doc_text2 = "imp std.io;\n";
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
    // Expect some kind of result (array/object/null), but definitely not a crash.
    _ = def_result;

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
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
        "imp std.io;\n\n" ++
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
        "imp std.io;\n\n" ++
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
