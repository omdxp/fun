const std = @import("std");

pub fn main() !void {
    return std.testing.main();
}

const Allocator = std.mem.Allocator;

/// Compatibility shim: ArrayList with embedded allocator (old-style managed API).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const ReaderCtx = struct {
    allocator: Allocator,
    stdout_file: *std.Io.File,
    q: *MsgQueue,
};

fn platformExeName(base: []const u8) []const u8 {
    if (@import("builtin").os.tag != .windows) return base;
    if (std.mem.eql(u8, base, "fls")) return "fls.exe";
    if (std.mem.eql(u8, base, "fun")) return "fun.exe";
    return base;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

fn writeLspMessageRaw(file: std.Io.File, io: std.Io, json: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json.len});
    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, json);
}

fn readLspMessage(allocator: Allocator, r: *std.Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line_raw = try r.takeDelimiterInclusive('\n');
        if (line_raw.len == 0) return error.EndOfStream;
        const line = std.mem.trim(u8, line_raw, "\r\n");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const rest = std.mem.trim(u8, line["Content-Length:".len..], " ");
            content_length = try std.fmt.parseInt(usize, rest, 10);
        }
    }

    const len = content_length orelse return error.MissingContentLength;
    const msg = try allocator.alloc(u8, len);
    errdefer allocator.free(msg);
    try r.readSliceAll(msg);
    return msg;
}

const MsgQueue = struct {
    allocator: Allocator,
    mu: std.Io.Mutex = .init,
    cv: std.Io.Condition = .init,
    closed: bool = false,
    items: ArrayList([]u8),

    fn init(allocator: Allocator) MsgQueue {
        return .{ .allocator = allocator, .items = ArrayList([]u8).init(allocator) };
    }

    fn deinit(self: *MsgQueue) void {
        for (self.items.items) |m| self.allocator.free(m);
        self.items.deinit();
    }

    fn push(self: *MsgQueue, msg: []u8) void {
        const io = std.testing.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.items.append(msg) catch {
            self.allocator.free(msg);
            return;
        };
        self.cv.signal(io);
    }

    fn setClosed(self: *MsgQueue) void {
        const io = std.testing.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.closed = true;
        self.cv.broadcast(io);
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
        const io = std.testing.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

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
        const io = std.testing.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

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
    const io = std.testing.io;
    var read_buf: [65536]u8 = undefined;
    var reader = ctx.stdout_file.*.reader(io, &read_buf);
    while (true) {
        const msg = readLspMessage(ctx.allocator, &reader.interface) catch {
            ctx.q.setClosed();
            return;
        };
        ctx.q.push(msg);
    }
}

const LspProc = struct {
    allocator: Allocator,
    child: std.process.Child,
    stdin_box: *std.Io.File,
    stdout_box: *std.Io.File,
    q: *MsgQueue,
    reader: std.Thread,
    reader_ctx: *ReaderCtx,
    next_id: i64 = 1,

    fn start(allocator: Allocator, exe_path: []const u8, root_cwd: []const u8, fun_abs_path: []const u8) !LspProc {
        const io = std.testing.io;

        var env_map = try std.testing.environ.createMap(allocator);
        errdefer env_map.deinit();
        try env_map.put("FLS_FUN_PATH", fun_abs_path);
        // Ensure stdlib resolution uses the repo stdlib when tests index temp docs.
        try env_map.put("FUN_STDLIB_DIR", "stdlib");

        var child = try std.process.spawn(io, .{
            .argv = &.{exe_path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = .{ .path = root_cwd },
            .environ_map = &env_map,
        });
        // env_map is cloned by the OS at spawn; safe to deinit after.
        env_map.deinit();

        // Detach stdio handles into heap-stable storage so the reader thread
        // never references a stack temporary File (which would become invalid).
        const stdin_file = child.stdin orelse return error.MissingChildStdin;
        child.stdin = null;
        const stdout_file = child.stdout orelse return error.MissingChildStdout;
        child.stdout = null;

        const stdin_box = try allocator.create(std.Io.File);
        errdefer allocator.destroy(stdin_box);
        stdin_box.* = stdin_file;

        const stdout_box = try allocator.create(std.Io.File);
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
        const io = std.testing.io;
        // Best-effort shutdown of the child.
        // Close stdin first to signal EOF; don't close stdout until the reader thread is done.
        self.stdin_box.*.close(io);

        // Force-unblock the reader thread even if the OS doesn't immediately
        // deliver EOF on the pipe after killing the child.
        self.stdout_box.*.close(io);

        self.child.kill(io);
        // kill() already reaps the process (sets child.id = null); no wait() needed.

        self.reader.join();
        self.q.setClosed();
        self.q.deinit();
        self.allocator.destroy(self.q);
        self.allocator.destroy(self.reader_ctx);

        self.allocator.destroy(self.stdin_box);
        self.allocator.destroy(self.stdout_box);
    }

    fn sendRaw(self: *LspProc, json: []const u8) !void {
        const io = std.testing.io;
        try writeLspMessageRaw(self.stdin_box.*, io, json);
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
        const io = std.testing.io;
        const start_ms: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms));
        while (true) {
            if (self.q.popMatchingResponse(self.allocator, id)) |msg| return msg;

            const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms));
            if (now_ms - start_ms > timeout_ms) return error.Timeout;

            {
                self.q.mu.lockUncancelable(io);
                defer self.q.mu.unlock(io);
                if (self.q.closed) return error.EndOfStream;
            }
            // Wait a little; wakeups come from reader thread.
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .real) catch {};
        }
    }

    fn waitNotification(self: *LspProc, method: []const u8, timeout_ms: i64) !MsgQueue.ParsedMsg {
        const io = std.testing.io;
        const start_ms: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms));
        while (true) {
            if (self.q.popMatchingNotification(self.allocator, method)) |msg| return msg;

            const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms));
            if (now_ms - start_ms > timeout_ms) return error.Timeout;

            {
                self.q.mu.lockUncancelable(io);
                defer self.q.mu.unlock(io);
                if (self.q.closed) return error.EndOfStream;
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .real) catch {};
        }
    }
};

fn escapeJsonAlloc(allocator: Allocator, s: []const u8) ![]u8 {
    var out = ArrayList(u8).init(allocator);
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
    var out = ArrayList(u8).init(allocator);
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
            var candidates = ArrayList([]const u8).init(allocator_);
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
    const fun_abs = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, fun_path_rel_or_abs, &buf);
        break :blk try allocator.dupe(u8, buf[0..n]);
    };
    errdefer allocator.free(fun_abs);

    const root_abs = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, ".", &buf);
        break :blk try allocator.dupe(u8, buf[0..n]);
    };
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
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache") catch {};
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

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
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

fn expectLocationsContain(allocator: Allocator, result_val: std.json.Value, uri_contains: []const u8, line: i64, character: i64) !void {
    if (definitionResultHasLocation(result_val, uri_contains, line, character)) return;

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print(
            "\n[fls_e2e] locations expected uri contains '{s}' @ {d}:{d}\n{s}\n",
            .{ uri_contains, line, character, s },
        );
    } else {
        std.debug.print("\n[fls_e2e] locations mismatch (failed to stringify)\n", .{});
    }
    return error.TestUnexpectedResult;
}

fn workspaceEditCountUriNewText(result_val: std.json.Value, uri: []const u8, new_text: []const u8) usize {
    if (result_val != .object) return 0;
    const changes_val = result_val.object.get("changes") orelse return 0;
    if (changes_val != .object) return 0;
    const edits_val = changes_val.object.get(uri) orelse return 0;
    if (edits_val != .array) return 0;

    var count: usize = 0;
    for (edits_val.array.items) |edit_val| {
        if (edit_val != .object) continue;
        const nt = edit_val.object.get("newText") orelse continue;
        if (nt == .string and std.mem.eql(u8, nt.string, new_text)) {
            count += 1;
        }
    }
    return count;
}

fn expectRenameEditCountForUri(
    allocator: Allocator,
    result_val: std.json.Value,
    uri: []const u8,
    new_text: []const u8,
    expected_min_count: usize,
) !void {
    const count = workspaceEditCountUriNewText(result_val, uri, new_text);
    if (count >= expected_min_count) return;

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print(
            "\n[fls_e2e] rename expected at least {d} edits to '{s}' in uri '{s}', found {d}\n{s}\n",
            .{ expected_min_count, new_text, uri, count, s },
        );
    } else {
        std.debug.print("\n[fls_e2e] rename edit count mismatch (failed to stringify)\n", .{});
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

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
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

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] completion unexpectedly contains '{s}'\n{s}\n", .{ label, s });
    } else {
        std.debug.print("\n[fls_e2e] completion unexpectedly contains '{s}' (failed to stringify)\n", .{label});
    }

    return error.TestUnexpectedResult;
}

fn completionLabelDetailContains(result_val: std.json.Value, label: []const u8, needle: []const u8) bool {
    const itemMatches = struct {
        fn call(it: std.json.Value, label2: []const u8, needle2: []const u8) bool {
            if (it != .object) return false;
            const lbl = it.object.get("label") orelse return false;
            if (lbl != .string or !std.mem.eql(u8, lbl.string, label2)) return false;
            const detail = it.object.get("detail") orelse return false;
            if (detail != .string) return false;
            return std.mem.indexOf(u8, detail.string, needle2) != null;
        }
    }.call;

    switch (result_val) {
        .array => |arr| {
            for (arr.items) |it| {
                if (itemMatches(it, label, needle)) return true;
            }
            return false;
        },
        .object => |obj| {
            if (obj.get("items")) |items| {
                if (items == .array) {
                    for (items.array.items) |it| {
                        if (itemMatches(it, label, needle)) return true;
                    }
                }
            }
            return false;
        },
        else => return false,
    }
}

fn expectCompletionLabelDetailContains(allocator: Allocator, result_val: std.json.Value, label: []const u8, needle: []const u8) !void {
    if (completionLabelDetailContains(result_val, label, needle)) return;

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] completion detail for '{s}' missing '{s}'\n{s}\n", .{ label, needle, s });
    } else {
        std.debug.print("\n[fls_e2e] completion detail for '{s}' missing '{s}' (failed to stringify)\n", .{ label, needle });
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

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
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

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
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

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] signatureHelp parameters missing '{s}'\n{s}\n", .{ needle, s });
    }
    return error.TestUnexpectedResult;
}

fn expectHoverContains(allocator: Allocator, result_val: std.json.Value, needle: []const u8) !void {
    if (hoverContains(result_val, needle)) return;

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] hover missing '{s}'\n{s}\n", .{ needle, s });
    }
    return error.TestUnexpectedResult;
}

fn expectHoverNotContains(allocator: Allocator, result_val: std.json.Value, needle: []const u8) !void {
    if (!hoverContains(result_val, needle)) return;

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] hover unexpectedly contains '{s}'\n{s}\n", .{ needle, s });
    }
    return error.TestUnexpectedResult;
}

fn hoverContains(result_val: std.json.Value, needle: []const u8) bool {
    if (result_val == .null) return false;
    if (result_val != .object) return false;
    const obj = result_val.object;
    const contents = obj.get("contents") orelse return false;
    if (contents != .object) return false;
    const v = contents.object.get("value") orelse return false;
    if (v != .string) return false;
    return std.mem.indexOf(u8, v.string, needle) != null;
}

fn waitForCompletionLabel(allocator: Allocator, lsp: *LspProc, params_json: []const u8, label: []const u8, timeout_ms: i64) !void {
    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + timeout_ms;

    while (true) {
        const req_id = try lsp.request("textDocument/completion", params_json);
        var res = lsp.waitResponse(req_id, 5000) catch |err| switch (err) {
            error.Timeout => {
                if (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) >= deadline_ms) return err;
                continue;
            },
            else => return err,
        };
        defer res.deinit();

        const result_val = try jsonResultFromResponseObj(res.parsed.value.object);
        if (completionHasLabel(result_val, label)) return;
        if (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) >= deadline_ms) {
            return expectCompletionHasLabel(allocator, result_val, label);
        }

        std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(@intCast(100 * std.time.ns_per_ms)), .real) catch {};
    }
}

fn waitForHoverContains(allocator: Allocator, lsp: *LspProc, params_json: []const u8, needle: []const u8, timeout_ms: i64) !void {
    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + timeout_ms;

    while (true) {
        const req_id = try lsp.request("textDocument/hover", params_json);
        var res = lsp.waitResponse(req_id, 5000) catch |err| switch (err) {
            error.Timeout => {
                if (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) >= deadline_ms) return err;
                continue;
            },
            else => return err,
        };
        defer res.deinit();

        const result_val = try jsonResultFromResponseObj(res.parsed.value.object);
        if (hoverContains(result_val, needle)) return;
        if (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) >= deadline_ms) {
            return expectHoverContains(allocator, result_val, needle);
        }

        std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(@intCast(100 * std.time.ns_per_ms)), .real) catch {};
    }
}

fn codeActionHasTitleWithNewText(result_val: std.json.Value, title: []const u8, new_text: []const u8) bool {
    if (result_val != .array) return false;

    for (result_val.array.items) |item| {
        if (item != .object) continue;

        const title_val = item.object.get("title") orelse continue;
        if (title_val != .string or !std.mem.eql(u8, title_val.string, title)) continue;

        const edit_val = item.object.get("edit") orelse continue;
        if (edit_val != .object) continue;

        const changes_val = edit_val.object.get("changes") orelse continue;
        if (changes_val != .object) continue;

        var it = changes_val.object.iterator();
        while (it.next()) |entry| {
            const edits_val = entry.value_ptr.*;
            if (edits_val != .array) continue;
            for (edits_val.array.items) |ev| {
                if (ev != .object) continue;
                const nt = ev.object.get("newText") orelse continue;
                if (nt == .string and std.mem.eql(u8, nt.string, new_text)) return true;
            }
        }
    }

    return false;
}

fn expectCodeActionHasTitleWithNewText(allocator: Allocator, result_val: std.json.Value, title: []const u8, new_text: []const u8) !void {
    if (codeActionHasTitleWithNewText(result_val, title, new_text)) return;

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] codeAction missing title '{s}' with newText '{s}'\n{s}\n", .{ title, new_text, s });
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

    const dumped = blk: {
        var _aw = std.Io.Writer.Allocating.init(allocator);
        defer _aw.deinit();
        std.json.fmt(result_val, .{}).format(&_aw.writer) catch break :blk null;
        const _s = _aw.toOwnedSlice() catch break :blk null;
        break :blk _s;
    };
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

    // 45s (not the usual 5s): this is the first request the test issues
    // after opening the doc, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const sym_id = try lsp.request("textDocument/documentSymbol", sym_params);
    var sym_res = try lsp.waitResponse(sym_id, 45000);
    defer sym_res.deinit();

    // Expect a symbol list response (ideally includes factorial/main).
    try std.testing.expect(sym_res.parsed.value == .object);
    const sym_obj = sym_res.parsed.value.object;
    try std.testing.expect(sym_obj.get("result") != null);

    // Build the expected post-change text so we can compute correct positions after didChange.
    const insert_index = try byteIndexFromLineCol(doc_text, insert_pos.line, end_col);
    var new_doc = ArrayList(u8).init(allocator);
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

test "fls e2e: indexing edge-case workspace files does not crash server" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // First workspace/symbol call lazily triggers the full-workspace scan
    // (see indexWorkspace); CI runners are slower than local, so give it room.
    const slow_timeout_ms = 60000;

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const rel_paths = [_][]const u8{
        "examples/error_cases/private_quirk_method_access.fn",
        "examples/imports/alias_module_scope.fn",
    };

    for (rel_paths) |rel| {
        const abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, rel });
        defer allocator.free(abs);

        const src = blk: {
            var f = try std.Io.Dir.openFileAbsolute(std.testing.io, abs, .{});
            defer f.close(std.testing.io);
            break :blk try blk2: {
                var _rb: [65536]u8 = undefined;
                var _fr = f.reader(std.testing.io, &_rb);
                break :blk2 _fr.interface.allocRemaining(allocator, .limited(512 * 1024));
            };
        };
        defer allocator.free(src);

        const doc_uri = try pathToFileUriAlloc(allocator, abs);
        defer allocator.free(doc_uri);

        try lspOpenDoc(allocator, &lsp, doc_uri, 1, src);

        const ds_params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}",
            .{doc_uri},
        );
        defer allocator.free(ds_params);
        const ds_id = try lsp.request("textDocument/documentSymbol", ds_params);
        var ds_res = try lsp.waitResponse(ds_id, slow_timeout_ms);
        defer ds_res.deinit();
        _ = try jsonResultFromResponseObj(ds_res.parsed.value.object);
    }

    // Keep pinging after opens so a late async indexing crash is surfaced.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const ws_id = try lsp.request("workspace/symbol", "{\"query\":\"main\"}");
        var ws_res = try lsp.waitResponse(ws_id, slow_timeout_ms);
        defer ws_res.deinit();
        _ = try jsonResultFromResponseObj(ws_res.parsed.value.object);
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: workspace indexing survives multiple malformed files" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // First workspace/symbol call lazily triggers the full-workspace scan
    // (see indexWorkspace); CI runners are slower than local, so give it room.
    const slow_timeout_ms = 60000;

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    const tmp_rel_dir = "tests/_fls_e2e_index_regress";
    std.Io.Dir.cwd().createDirPath(std.testing.io, tmp_rel_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_rel_dir) catch {};

    const malformed = [_]struct { rel: []const u8, text: []const u8 }{
        .{
            .rel = "tests/_fls_e2e_index_regress/malformed_bin_rhs.fn",
            .text = "fun main() {\n" ++
                "  num x = 1 + ;\n" ++
                "  ret;\n" ++
                "}\n",
        },
        .{
            .rel = "tests/_fls_e2e_index_regress/malformed_fit_dot.fn",
            .text = "fun main() {\n" ++
                "  num x = 1;\n" ++
                "  fit x {\n" ++
                "    . -> { ret; },\n" ++
                "  }\n" ++
                "}\n",
        },
        .{
            .rel = "tests/_fls_e2e_index_regress/malformed_import_dot.fn",
            .text = "imp std.;\n" ++
                "fun main() {\n" ++
                "  ret;\n" ++
                "}\n",
        },
    };

    for (malformed) |mf| {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, mf.rel, .{ .read = true, .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, mf.text);
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    for (malformed) |mf| {
        const abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, mf.rel });
        defer allocator.free(abs);
        const doc_uri = try pathToFileUriAlloc(allocator, abs);
        defer allocator.free(doc_uri);

        try lspOpenDoc(allocator, &lsp, doc_uri, 1, mf.text);

        const ds_params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}",
            .{doc_uri},
        );
        defer allocator.free(ds_params);
        const ds_id = try lsp.request("textDocument/documentSymbol", ds_params);
        var ds_res = try lsp.waitResponse(ds_id, slow_timeout_ms);
        defer ds_res.deinit();
        _ = try jsonResultFromResponseObj(ds_res.parsed.value.object);
    }

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const ws_id = try lsp.request("workspace/symbol", "{\"query\":\"main\"}");
        var ws_res = try lsp.waitResponse(ws_id, slow_timeout_ms);
        defer ws_res.deinit();
        _ = try jsonResultFromResponseObj(ws_res.parsed.value.object);
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: formatting never returns empty output" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    try waitForCompletionLabel(allocator, &lsp, int_params, "INT_MAX", 15000);

    // Completion at end of `NUL` should include `NULL`.
    const nul_pos = try findPosition(doc_text, "NUL;", 0);
    const nul_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, nul_pos.line, nul_pos.col + @as(i64, @intCast("NUL".len)) },
    );
    defer allocator.free(nul_params);
    try waitForCompletionLabel(allocator, &lsp, nul_params, "NULL", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: std namespace hover shows README and module docs" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

test "fls e2e: dot-shorthand completion for a compound-init field's own value" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound Task {\n" ++
        "  str title;\n" ++
        "  Priority priority;\n" ++
        "}\n\n" ++
        "enum Priority {\n" ++
        "  Low,\n" ++
        "  High,\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Task explicit = Task{title = \"Ship\", priority = .High};\n" ++
        "  Task bare = .{title = \"Ship\", priority = .High};\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-compound-init-field-dot.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // `Task{..., priority = .High}` -- explicit compound-init.
    const explicit_pos = try findPosition(doc_text, "Task{title = \"Ship\", priority = .", 0);
    const explicit_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, explicit_pos.line, explicit_pos.col + @as(i64, @intCast("Task{title = \"Ship\", priority = .".len)) },
    );
    defer allocator.free(explicit_params);
    const explicit_id = try lsp.request("textDocument/completion", explicit_params);
    var explicit_res = try lsp.waitResponse(explicit_id, 15000);
    defer explicit_res.deinit();
    const explicit_result = try jsonResultFromResponseObj(explicit_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, explicit_result, "High");

    // `.{..., priority = .High}` -- bare shorthand compound-init, expected type
    // inferred from the enclosing `Task bare = ...` declaration.
    const bare_pos = try findPosition(doc_text, ".{title = \"Ship\", priority = .", 0);
    const bare_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, bare_pos.line, bare_pos.col + @as(i64, @intCast(".{title = \"Ship\", priority = .".len)) },
    );
    defer allocator.free(bare_params);
    const bare_id = try lsp.request("textDocument/completion", bare_params);
    var bare_res = try lsp.waitResponse(bare_id, 15000);
    defer bare_res.deinit();
    const bare_result = try jsonResultFromResponseObj(bare_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, bare_result, "High");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: hover on a dot-shorthand nested inside an enum-constructor call's args" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.option;\n" ++
        "imp std.result;\n\n" ++
        "pub next_or_none() Result<Option<num>, Error> {\n" ++
        "  ret .Ok(.None);\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  let r = next_or_none();\n" ++
        "  _ = r;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-nested-dot-shorthand.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hovering the NESTED `.None` (the payload of the outer `.Ok(...)` construction)
    // must resolve it against `Option`, not against the outer `Result` (which has
    // no `None` variant at all -- misattributing it there previously produced no
    // hover), and not silently produce nothing either.
    const none_pos = try findPosition(doc_text, ".None", 0);
    const hover_none_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, none_pos.line, none_pos.col + 1 },
    );
    defer allocator.free(hover_none_params);
    const hover_none_id = try lsp.request("textDocument/hover", hover_none_params);
    var hover_none_res = try lsp.waitResponse(hover_none_id, 15000);
    defer hover_none_res.deinit();
    const hover_none_val = try jsonResultFromResponseObj(hover_none_res.parsed.value.object);
    try expectHoverContains(allocator, hover_none_val, "Option");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: hover distinguishes const bindings from plain variables" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "pub const num TOP_EXPLICIT = 1;\n" ++
        "pub const TOP_INFERRED = 2;\n\n" ++
        "fun main() {\n" ++
        "  const num local_explicit = 3;\n" ++
        "  const local_inferred = 4;\n" ++
        "  num plain = 5;\n" ++
        "  _ = local_explicit;\n" ++
        "  _ = local_inferred;\n" ++
        "  _ = plain;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-const-hover.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const top_explicit_pos = try findPosition(doc_text, "TOP_EXPLICIT", 0);
    const top_explicit_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, top_explicit_pos.line, top_explicit_pos.col },
    );
    defer allocator.free(top_explicit_params);
    const top_explicit_id = try lsp.request("textDocument/hover", top_explicit_params);
    var top_explicit_res = try lsp.waitResponse(top_explicit_id, 15000);
    defer top_explicit_res.deinit();
    const top_explicit_hover = try jsonResultFromResponseObj(top_explicit_res.parsed.value.object);
    try expectHoverContains(allocator, top_explicit_hover, "const");

    const top_inferred_pos = try findPosition(doc_text, "TOP_INFERRED", 0);
    const top_inferred_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, top_inferred_pos.line, top_inferred_pos.col },
    );
    defer allocator.free(top_inferred_params);
    const top_inferred_id = try lsp.request("textDocument/hover", top_inferred_params);
    var top_inferred_res = try lsp.waitResponse(top_inferred_id, 15000);
    defer top_inferred_res.deinit();
    const top_inferred_hover = try jsonResultFromResponseObj(top_inferred_res.parsed.value.object);
    try expectHoverContains(allocator, top_inferred_hover, "const");

    const local_explicit_pos = try findPosition(doc_text, "local_explicit = 3", 0);
    const local_explicit_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, local_explicit_pos.line, local_explicit_pos.col },
    );
    defer allocator.free(local_explicit_params);
    const local_explicit_id = try lsp.request("textDocument/hover", local_explicit_params);
    var local_explicit_res = try lsp.waitResponse(local_explicit_id, 15000);
    defer local_explicit_res.deinit();
    const local_explicit_hover = try jsonResultFromResponseObj(local_explicit_res.parsed.value.object);
    try expectHoverContains(allocator, local_explicit_hover, "const");

    const local_inferred_pos = try findPosition(doc_text, "local_inferred = 4", 0);
    const local_inferred_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, local_inferred_pos.line, local_inferred_pos.col },
    );
    defer allocator.free(local_inferred_params);
    const local_inferred_id = try lsp.request("textDocument/hover", local_inferred_params);
    var local_inferred_res = try lsp.waitResponse(local_inferred_id, 15000);
    defer local_inferred_res.deinit();
    const local_inferred_hover = try jsonResultFromResponseObj(local_inferred_res.parsed.value.object);
    try expectHoverContains(allocator, local_inferred_hover, "const");

    // A plain (non-const) variable must NOT show `const` in its hover.
    const plain_pos = try findPosition(doc_text, "plain = 5", 0);
    const plain_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, plain_pos.line, plain_pos.col },
    );
    defer allocator.free(plain_params);
    const plain_id = try lsp.request("textDocument/hover", plain_params);
    var plain_res = try lsp.waitResponse(plain_id, 15000);
    defer plain_res.deinit();
    const plain_hover = try jsonResultFromResponseObj(plain_res.parsed.value.object);
    try expectHoverNotContains(allocator, plain_hover, "const");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: dot-shorthand in a fit whose subject is a method call returning a generic enum" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // The fit SUBJECT is a method call returning a generic enum (`b.peek()` -> `RR<num>`).
    // A shorthand `.Ok` arm must resolve to `RR.Ok` via the subject's method-call return
    // type — not just bare-variable or free-call subjects. (Regression: previously only
    // those simpler subject forms resolved; a method-call subject gave empty hover/def.)
    const doc_text =
        "imp std.c.io;\n\n" ++
        "enum RR<T> {\n" ++
        "  Ok(T),\n" ++
        "  Empty,\n" ++
        "}\n\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n\n" ++
        "impl Box<T> {\n" ++
        "  pub peek() RR<T> {\n" ++
        "    ret RR.Ok(self.v);\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun main() num {\n" ++
        "  Box<num> b;\n" ++
        "  b.v = 5;\n" ++
        "  fit b.peek() {\n" ++
        "    .Ok(v) -> { printf(\"%lld\\n\", v); }\n" ++
        "    .Empty -> { printf(\"empty\\n\"); }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fit-methodcall-shorthand.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover the shorthand `.Ok` arm -> resolves to the RR.Ok variant.
    const ok_pos = try findPosition(doc_text, ".Ok(v) ->", 0);
    const ok_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, ok_pos.line, ok_pos.col + 1 },
    );
    defer allocator.free(ok_params);
    try waitForHoverContains(allocator, &lsp, ok_params, "RR.Ok", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: dot-shorthand in a fit whose subject is `await <method-call>`" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // The fit SUBJECT is `await b.peek()` — an awaited method call returning a generic
    // enum. The leading `await` keyword must be skipped so the shorthand `.Ok` arm
    // resolves via the awaited call's return type. (Regression: `fit await <call>` gave
    // empty hover/def because subject resolution bailed on the `await` keyword.)
    const doc_text =
        "imp std.c.io;\n\n" ++
        "enum RR<T> {\n" ++
        "  Ok(T),\n" ++
        "  Empty,\n" ++
        "}\n\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n\n" ++
        "impl Box<T> {\n" ++
        "  pub async peek() RR<T> {\n" ++
        "    ret RR.Ok(self.v);\n" ++
        "  }\n" ++
        "}\n\n" ++
        "async fun run() {\n" ++
        "  Box<num> b;\n" ++
        "  b.v = 5;\n" ++
        "  fit await b.peek() {\n" ++
        "    .Ok(v) -> { printf(\"%lld\\n\", v); }\n" ++
        "    .Empty -> { printf(\"empty\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fit-await-shorthand.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const ok_pos = try findPosition(doc_text, ".Ok(v) ->", 0);
    const ok_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, ok_pos.line, ok_pos.col + 1 },
    );
    defer allocator.free(ok_params);
    try waitForHoverContains(allocator, &lsp, ok_params, "RR.Ok", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: cross-file generic fit-binding hover resolves the imported enum's payload" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // `Result` is the IMPORTED generic enum (std.result). The `Ok(T)` payload binding
    // `doc` must hover as `JsonValue` (the subject's concrete arg) and the `Err(Error)`
    // payload `e` as `Error` — resolved cross-file from the imported enum definition.
    const doc_text =
        "imp std.c.io;\n" ++
        "imp std.error;\n" ++
        "imp std.json;\n" ++
        "imp std.result;\n\n" ++
        "fun main() num {\n" ++
        "  Result<JsonValue, Error> r = parse(\"{}\");\n" ++
        "  fit r {\n" ++
        "    Result.Ok(doc) -> { printf(\"ok\\n\"); }\n" ++
        "    Result.Err(e) -> { printf(\"err\\n\"); }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-xfile-fitbind.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover the `doc` binding -> `JsonValue`.
    const doc_pos = try findPosition(doc_text, "Ok(doc)", 0);
    const doc_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, doc_pos.line, doc_pos.col + @as(i64, @intCast("Ok(".len)) },
    );
    defer allocator.free(doc_params);
    const doc_id = try lsp.request("textDocument/hover", doc_params);
    var doc_res = try lsp.waitResponse(doc_id, 15000);
    defer doc_res.deinit();
    try expectHoverContains(allocator, try jsonResultFromResponseObj(doc_res.parsed.value.object), "JsonValue");

    // Hover the `e` binding -> `Error` (concrete payload of Result.Err).
    const e_pos = try findPosition(doc_text, "Err(e)", 0);
    const e_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, e_pos.line, e_pos.col + @as(i64, @intCast("Err(".len)) },
    );
    defer allocator.free(e_params);
    const e_id = try lsp.request("textDocument/hover", e_params);
    var e_res = try lsp.waitResponse(e_id, 15000);
    defer e_res.deinit();
    try expectHoverContains(allocator, try jsonResultFromResponseObj(e_res.parsed.value.object), "Error");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: cross-file dot-shorthand hover resolves a plain (non-generic) enum variant" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    // A plain, non-generic enum with no-payload variants, defined in a SEPARATE
    // file from the one that `fit`-matches it via bare dot-shorthand.
    const mod_dir_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "fls_e2e_xfile_plain_enum" });
    defer allocator.free(mod_dir_abs);
    std.Io.Dir.createDirAbsolute(std.testing.io, mod_dir_abs, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, mod_dir_abs) catch {};

    const defs_abs = try std.fs.path.join(allocator, &[_][]const u8{ mod_dir_abs, "defs.fn" });
    defer allocator.free(defs_abs);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, defs_abs, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
            "pub enum Kind {\n" ++
                "  UnsupportedNode,\n" ++
                "  InvalidNode,\n" ++
                "}\n",
        );
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp fls_e2e_xfile_plain_enum.defs;\n\n" ++
        "fun describe(Kind k) str {\n" ++
        "  fit k {\n" ++
        "    .UnsupportedNode -> { ret \"a\"; }\n" ++
        "    .InvalidNode -> { ret \"b\"; }\n" ++
        "  }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-xfile-plain-enum-main.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hovering the bare `.InvalidNode` shorthand (no `Kind.` qualifier) must
    // resolve cross-file to the imported enum's variant, not come back empty.
    const pos = try findPosition(doc_text, ".InvalidNode", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + 2 },
    );
    defer allocator.free(hover_params);
    // Longer budget than the usual 15000ms (matching the workspace-symbol
    // test's own 45000ms precedent): resolving a cross-file import against
    // the real, full repo root is measurably slower than an isolated fixture.
    try waitForHoverContains(allocator, &lsp, hover_params, "Kind.InvalidNode", 45000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: query-time engine resolves a fit->let-chain->for-each binding cascade" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // The hard cascade: `doc` is an imported-generic-enum fit payload (JsonValue);
    // `items` is a `let` from the method chain `doc.as_array().unwrap_or(...)` (which
    // must follow `as_array(): Option<Vec<JsonValue>>` then specialize `unwrap_or` to
    // `Vec<JsonValue>`); `item` is the for-each element type of `items` (JsonValue).
    // All three are typed by the query-time expression engine, not the index.
    const doc_text =
        "imp std.c.io;\n" ++
        "imp std.json;\n" ++
        "imp std.option;\n" ++
        "imp std.result;\n" ++
        "imp std.vec;\n\n" ++
        "fun main() num {\n" ++
        "  fit parse(\"[1,2,3]\") {\n" ++
        "    Result.Ok(doc) -> {\n" ++
        "      let items = doc.as_array().unwrap_or(json_array());\n" ++
        "      for item : items {\n" ++
        "        printf(\"%g\\n\", item.as_num().unwrap_or(0.0));\n" ++
        "      }\n" ++
        "    }\n" ++
        "    Result.Err(e) -> { printf(\"err\\n\"); }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-cascade.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const Case = struct { find: []const u8, off: usize, want: []const u8 };
    const cases = [_]Case{
        .{ .find = "Ok(doc)", .off = "Ok(".len, .want = "JsonValue" }, // fit payload
        .{ .find = "let items", .off = "let ".len, .want = "Vec<JsonValue>" }, // let from chain
        .{ .find = "for item :", .off = "for ".len, .want = "JsonValue" }, // for-each element
        // A method whose RECEIVER is itself a call (`as_array().unwrap_or`): hover must
        // show the specialized signature (receiver `Option<Vec<JsonValue>>` -> `T` is
        // `Vec<JsonValue>`), not empty. Regresses the chained-receiver resolution.
        .{ .find = ".unwrap_or(json_array())", .off = ".".len, .want = "Vec<JsonValue>" },
    };
    for (cases) |c| {
        const pos = try findPosition(doc_text, c.find, 0);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + @as(i64, @intCast(c.off)) },
        );
        defer allocator.free(params);
        const hid = try lsp.request("textDocument/hover", params);
        var res = try lsp.waitResponse(hid, 15000);
        defer res.deinit();
        try expectHoverContains(allocator, try jsonResultFromResponseObj(res.parsed.value.object), c.want);
    }

    // Go-to-definition on the chained `unwrap_or` must jump into std/option.fn
    // (not return an empty result).
    {
        const pos = try findPosition(doc_text, ".unwrap_or(json_array())", 0);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + @as(i64, @intCast(".".len)) },
        );
        defer allocator.free(params);
        const did = try lsp.request("textDocument/definition", params);
        var dres = try lsp.waitResponse(did, 15000);
        defer dres.deinit();
        const dval = try jsonResultFromResponseObj(dres.parsed.value.object);
        // Expect a non-empty location array pointing at option.fn.
        try std.testing.expect(dval == .array and dval.array.items.len > 0);
        const loc0 = dval.array.items[0];
        const def_uri = loc0.object.get("uri").?.string;
        try std.testing.expect(std.mem.indexOf(u8, def_uri, "option.fn") != null);
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: go-to-definition resolves the correct token when non-ASCII content precedes it on the same line" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // LSP positions are UTF-16 code-unit offsets. An em dash ("\u{2014}")
    // is 1 UTF-16 unit but 3 UTF-8 bytes, so a real client's `character` for
    // the start of `helper` here is LESS than the byte offset would be — if
    // fls mis-treats `character` as a raw byte count, it under-shoots and
    // resolves to whatever token sits a couple of bytes to the left (here,
    // the `=` sign) instead of `helper`, and go-to-definition comes back
    // empty/wrong.
    const prefix1 = "  str note = \"";
    const em_dash = "\u{2014}";
    const prefix2 = "\"; num x = ";
    const doc_text =
        "imp std.c.io;\n" ++
        "fun helper() num { ret 7; }\n" ++
        "fun main() num {\n" ++
        prefix1 ++ em_dash ++ prefix2 ++ "helper();\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-utf16-position.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const line_pos = try findPosition(doc_text, prefix1, 0);
    const target_char: i64 = @intCast(prefix1.len + 1 + prefix2.len); // +1 UTF-16 unit for the em dash

    const def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, line_pos.line, target_char },
    );
    defer allocator.free(def_params);

    const did = try lsp.request("textDocument/definition", def_params);
    var dres = try lsp.waitResponse(did, 15000);
    defer dres.deinit();
    const dval = try jsonResultFromResponseObj(dres.parsed.value.object);

    const decl_pos = try findPosition(doc_text, "fun helper", 0);
    try expectDefinitionPointsTo(allocator, dval, doc_uri, decl_pos.line, decl_pos.col + 4);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: go-to-definition and hover on a method chained onto a real (non-free-function) method call" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Open the REAL example file verbatim, at its REAL path, rather than a
    // hand-typed excerpt — a reported "go-to-definition on the chained method
    // does nothing" complaint pointed at this exact file/line
    // (`v.as_num().unwrap_or(0.0)` in examples/stdlib/serde_json_toml.fn), and
    // a trimmed synthetic repro of just that snippet did not reproduce it, so
    // this test uses the unmodified file in case the surrounding context
    // (the `to()` impl, `main()`'s other statements, the `To<str>` usage)
    // matters.
    const rel_path = "examples/stdlib/serde_json_toml.fn";
    const doc_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rel_path, allocator, .limited(1024 * 1024));
    defer allocator.free(doc_text);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const doc_abs_len = try std.Io.Dir.cwd().realPathFile(std.testing.io, rel_path, &path_buf);
    const doc_uri = try pathToFileUriAlloc(allocator, path_buf[0..doc_abs_len]);
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Try every column across "unwrap_or" in `v.as_num().unwrap_or(0.0)` —
    // any off-by-one in cursor->token mapping for a chained-call receiver
    // would show up as an empty result at some (but not all) columns.
    const pos = try findPosition(doc_text, "v.as_num().unwrap_or(0.0)", 0);
    const base_off = "v.as_num().".len;
    var col_off: i64 = 0;
    while (col_off < @as(i64, @intCast("unwrap_or".len))) : (col_off += 1) {
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + @as(i64, @intCast(base_off)) + col_off },
        );
        defer allocator.free(params);
        const did = try lsp.request("textDocument/definition", params);
        var dres = try lsp.waitResponse(did, 15000);
        defer dres.deinit();
        const dval = try jsonResultFromResponseObj(dres.parsed.value.object);
        try std.testing.expect(dval == .array and dval.array.items.len > 0);
        const def_uri = dval.array.items[0].object.get("uri").?.string;
        try std.testing.expect(std.mem.indexOf(u8, def_uri, "option.fn") != null);
    }

    // Simulate normal editing (type a character, then delete it — net-zero
    // text change, so every position below stays valid) via incremental
    // `didChange` BEFORE re-querying go-to-definition, since a real editing
    // session sends these constantly and the reported bug was only ever
    // seen live, never on a freshly-opened, never-edited document.
    {
        const insert_json = try escapeJsonAlloc(allocator, "x");
        defer allocator.free(insert_json);
        const did_change_insert = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[" ++
                "{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"text\":\"{s}\"}}]}}",
            .{ doc_uri, insert_json },
        );
        defer allocator.free(did_change_insert);
        try lsp.notify("textDocument/didChange", did_change_insert);

        const did_change_delete = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":3}},\"contentChanges\":[" ++
                "{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":1}}}},\"text\":\"\"}}]}}",
            .{doc_uri},
        );
        defer allocator.free(did_change_delete);
        try lsp.notify("textDocument/didChange", did_change_delete);
    }

    // Same check on the FIRST `unwrap_or` in the file — chained onto
    // `value.get("name")`, i.e. onto a method call on a function PARAMETER
    // (not a `let`-bound local like `v`/`n`/`s`), with a shorthand enum
    // literal (`JsonValue.Null`) as the argument. This is a different
    // receiver-resolution path than the `v.as_num().unwrap_or(0.0)` case
    // above and was reported to still fail go-to-definition even after that
    // one was fixed.
    {
        const pos2 = try findPosition(doc_text, "value.get(\"name\").unwrap_or(JsonValue.Null)", 0);
        const base_off2 = "value.get(\"name\").".len;
        var col_off2: i64 = 0;
        while (col_off2 < @as(i64, @intCast("unwrap_or".len))) : (col_off2 += 1) {
            const params = try std.fmt.allocPrint(
                allocator,
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
                .{ doc_uri, pos2.line, pos2.col + @as(i64, @intCast(base_off2)) + col_off2 },
            );
            defer allocator.free(params);
            const did = try lsp.request("textDocument/definition", params);
            var dres = try lsp.waitResponse(did, 15000);
            defer dres.deinit();
            const dval = try jsonResultFromResponseObj(dres.parsed.value.object);
            try std.testing.expect(dval == .array and dval.array.items.len > 0);
            const def_uri = dval.array.items[0].object.get("uri").?.string;
            try std.testing.expect(std.mem.indexOf(u8, def_uri, "option.fn") != null);
        }
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: server stays responsive across malformed/mid-edit snippets (no hang/crash)" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const snippets = [_][]const u8{
        // Incomplete generic constraint clause.
        "imp std.io;\nfun f<T: >(T x) T { ret x; }\n",
        "imp std.io;\nfun f<T: num |>(T x) T { ret x; }\n",
        "imp std.io;\nfun f<T: num | str\n",
        "compound Boxed<T: >{ T value; }\n",
        "compound Boxed<T: num |\n",
        // Incomplete fit branch / pattern.
        "imp std.option;\nfun main() num {\n  Option<num> o = some(1);\n  fit o {\n    Option.Some(\n",
        "imp std.option;\nfun main() num {\n  Option<num> o = some(1);\n  fit o {\n    Option.\n",
        "imp std.option;\nfun main() num {\n  Option<num> o = some(1);\n  fit o {\n    .Some(n) ->\n",
        // Chained call cut off mid-dot.
        "imp std.string;\nfun main() num {\n  let x = trim(\"a\").\n  ret 0;\n}\n",
        "imp std.string;\nfun main() num {\n  let x = trim(\"a\").trim(\n",
        // Incomplete quirk impl.
        "imp std.quirks;\ncompound P{ num x; }\nimpl P as To<\n",
        "imp std.quirks;\ncompound P{ num x; }\nimpl P as To<num> {\n  pub to() num {\n",
        // Unterminated generic type annotation.
        "imp std.vec;\nfun main() num {\n  Vec<num\n",
        "imp std.vec;\nfun main() num {\n  Vec<Vec<num>\n",
        // sizeof edge cases (the constrained-generic sizeof fix's neighborhood).
        "compound Node<T>{ T v; }\nfun f<T>(T v) num { ret sizeof(Node<\n",
        "compound Node<T>{ T v; }\nfun f<T>(T v) num { ret sizeof(\n",
        // Empty / whitespace-only / just a dot.
        "",
        ".",
        "   \n\t\n",
    };

    // The very first request in the session pays a one-time workspace-indexing
    // cost (slower still in a Debug test build, which uses Zig's safety-checked
    // allocator) — give it a generous timeout so that startup cost alone can't
    // cause a false failure. Everything after should be fast; a genuinely hung
    // server fails regardless of how long we wait, so later requests use a
    // tighter bound.
    var first_request = true;

    for (snippets, 0..) |text, i| {
        const doc_uri = try std.fmt.allocPrint(allocator, "{s}fuzz_{d}.fn", .{ setup.root_uri, i });
        defer allocator.free(doc_uri);
        try lspOpenDoc(allocator, &lsp, doc_uri, 1, text);

        // Request hover at a handful of positions scattered across the (short)
        // document; a dead/hung server shows up as a response timeout here.
        var line: i64 = 0;
        while (line < 6) : (line += 1) {
            const params = try std.fmt.allocPrint(
                allocator,
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":3}}}}",
                .{ doc_uri, line },
            );
            defer allocator.free(params);
            const hid = try lsp.request("textDocument/hover", params);
            const timeout_ms: i64 = if (first_request) 20000 else 4000;
            first_request = false;
            var res = lsp.waitResponse(hid, timeout_ms) catch {
                std.debug.print("FAIL: snippet #{d} ({s}...) — server unresponsive on hover\n", .{ i, text[0..@min(text.len, 40)] });
                return error.ServerUnresponsive;
            };
            res.deinit();
        }

        // Also fire a completion request right at the end of the document —
        // exactly "typing `.` and nothing autocompletes" from the report, plus
        // it's a different request path than hover.
        const end_params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":20,\"character\":0}}}}",
            .{doc_uri},
        );
        defer allocator.free(end_params);
        const cid = try lsp.request("textDocument/completion", end_params);
        var cres = lsp.waitResponse(cid, 4000) catch {
            std.debug.print("FAIL: snippet #{d} ({s}...) — server unresponsive on completion\n", .{ i, text[0..@min(text.len, 40)] });
            return error.ServerUnresponsive;
        };
        cres.deinit();
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: fit branch variant hover shows the concrete generic arg, not the bare type param" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // `o` is `Option<dec>`. The payload binding `n` (inside the parens)
    // already hovers as the concrete `dec` — this regresses the BRANCH
    // VARIANT NAME itself (`Some`), which should also show `dec`, not the
    // enum's bare declared type param `T`.
    const doc_text =
        "imp std.c.io;\n" ++
        "imp std.option;\n\n" ++
        "fun main() num {\n" ++
        "  Option<dec> o = some(3.5);\n" ++
        "  fit o {\n" ++
        "    Option.Some(n) -> { printf(\"%f\\n\", n); }\n" ++
        "    Option.None -> {}\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fit-branch-variant-hover.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on the payload binding `n` (already correct: concrete `dec`).
    {
        const pos = try findPosition(doc_text, "Option.Some(n)", 0);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + @as(i64, @intCast("Option.Some(".len)) },
        );
        defer allocator.free(params);
        const hid = try lsp.request("textDocument/hover", params);
        var res = try lsp.waitResponse(hid, 15000);
        defer res.deinit();
        try expectHoverContains(allocator, try jsonResultFromResponseObj(res.parsed.value.object), "dec");
    }

    // Hover on the branch's own variant name `Some` (the reported bug: this
    // showed the bare type param, not `dec`).
    {
        const pos = try findPosition(doc_text, "Option.Some(n)", 0);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + @as(i64, @intCast("Option.".len)) },
        );
        defer allocator.free(params);
        const hid = try lsp.request("textDocument/hover", params);
        var res = try lsp.waitResponse(hid, 15000);
        defer res.deinit();
        try expectHoverContains(allocator, try jsonResultFromResponseObj(res.parsed.value.object), "dec");
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: data-carrying enum shorthand completion" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // A tagged-union enum: variants carry payloads. Completion after `.` in a
    // typed var-init should still offer the variant names, exactly like a plain
    // enum — the new payload syntax must not break dot-shorthand completion.
    // Use a unique enum name (`Geo`) to avoid colliding with `Shape`, which is a
    // quirk declared in examples/advanced/quirks.fn that the shared workspace index
    // also picks up.
    const doc_text =
        "imp std.c.io;\n\n" ++
        "enum Geo {\n" ++
        "  Circle(num),\n" ++
        "  Rect(num, num),\n" ++
        "  Empty,\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Geo s = .\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-data-enum.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const comp_pos = try findPosition(doc_text, "Geo s = .", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_pos.line, comp_pos.col + @as(i64, @intCast("Geo s = .".len)) },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result, "Circle");
    try expectCompletionHasLabel(allocator, comp_result, "Empty");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: generic type member completion (Vec<T>)" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

test "fls e2e: generic function call let inference" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n\n" ++
        "fun id<T>(T value) T {\n" ++
        "  ret value;\n" ++
        "}\n\n" ++
        "fun wrap<T>(T value) Box<T> {\n" ++
        "  ret Box<T>{v = value};\n" ++
        "}\n\n" ++
        "fun first<T, U>(T a, U b) T {\n" ++
        "  _ = b;\n" ++
        "  ret a;\n" ++
        "}\n\n" ++
        "fun second<T, U>(T a, U b) U {\n" ++
        "  _ = a;\n" ++
        "  ret b;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  let a = id(7);\n" ++
        "  let b = id<str>(\"x\");\n" ++
        "  let c = wrap(9);\n" ++
        "  let d = first(5, \"ok\");\n" ++
        "  let e = second(5, \"ok\");\n" ++
        "  let f = second<num, str>(1, \"z\");\n" ++
        "  let g = first<Box<num>, str>(Box<num>{v = 2}, \"q\");\n" ++
        "  let h = second<Box<num>, Box<str>>(Box<num>{v = 1}, Box<str>{v = \"a\"});\n" ++
        "  c.\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-generic-fun-let-infer.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const Case = struct { name: []const u8, expect: []const u8 };
    const cases = [_]Case{
        .{ .name = "a", .expect = "num a" },
        .{ .name = "b", .expect = "str b" },
        .{ .name = "c", .expect = "Box<num> c" },
        .{ .name = "d", .expect = "num d" },
        .{ .name = "e", .expect = "str e" },
        .{ .name = "f", .expect = "str f" },
        .{ .name = "g", .expect = "Box<num> g" },
        .{ .name = "h", .expect = "Box<str> h" },
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

    const dot_pos = try findPosition(doc_text, "  c.\n", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, dot_pos.line, dot_pos.col + @as(i64, @intCast("  c.".len)) },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_val = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_val, "v");
    try expectCompletionLabelDetailContains(allocator, comp_val, "v", "num");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: generic compound init member detail specializes field type" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound Box<T> {\n" ++
        "  T value;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  let nbox = Box{value = 7};\n" ++
        "  let x = nbox.value;\n" ++
        "  nbox.\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-generic-member-detail.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const dot_pos = try findPosition(doc_text, "  nbox.\n", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, dot_pos.line, dot_pos.col + @as(i64, @intCast("  nbox.".len)) },
    );
    defer allocator.free(comp_params);

    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_val = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_val, "value");
    try expectCompletionLabelDetailContains(allocator, comp_val, "value", "num");

    const value_pos = try findPosition(doc_text, "let x = nbox.value;", 0);
    const value_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, value_pos.line, value_pos.col + @as(i64, @intCast("let x = nbox.".len)) },
    );
    defer allocator.free(value_hover_params);

    const value_hover_id = try lsp.request("textDocument/hover", value_hover_params);
    var value_hover_res = try lsp.waitResponse(value_hover_id, 15000);
    defer value_hover_res.deinit();
    const value_hover_val = try jsonResultFromResponseObj(value_hover_res.parsed.value.object);
    try expectHoverContains(allocator, value_hover_val, "num value");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: generic compound init offers field-name completion" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Field-name completion inside an EXPLICITLY-GENERIC compound initializer
    // (`Box<num>{ <cursor> }`). The type name before `{` is `Box<num>`; FLS must
    // skip the `<num>` generic args to recover the base type `Box` and offer its
    // field `value`. (A non-generic `Point{` already worked; this guards the
    // generic-args handling.)
    const doc_text =
        "compound Box<T> {\n" ++
        "  T value;\n" ++
        "  num tag;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Box<num> b = Box<num>{ \n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-generic-init-fields.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Cursor right after `Box<num>{ ` (inside the braces).
    const init_pos = try findPosition(doc_text, "Box<num>{ ", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, init_pos.line, init_pos.col + @as(i64, @intCast("Box<num>{ ".len)) },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result, "value");
    try expectCompletionHasLabel(allocator, comp_result, "tag");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: custom import namespace hover shows README" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    // Create a custom module directory with a README.
    const mod_dir_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "mylib" });
    defer allocator.free(mod_dir_abs);
    std.Io.Dir.createDirAbsolute(std.testing.io, mod_dir_abs, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, mod_dir_abs) catch {};

    const readme_abs = try std.fs.path.join(allocator, &[_][]const u8{ mod_dir_abs, "README.md" });
    defer allocator.free(readme_abs);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, readme_abs, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "# MyLib\n\nCustom module README hover works.\n");
    }

    // Create a module file so `imp mylib.foo;` is a valid import.
    const foo_abs = try std.fs.path.join(allocator, &[_][]const u8{ mod_dir_abs, "foo.fn" });
    defer allocator.free(foo_abs);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, foo_abs, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
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
        .{ doc_uri, pos.line, pos.col + 2 },
    );
    defer allocator.free(hover_params);

    try waitForHoverContains(allocator, &lsp, hover_params, "MyLib", 15000);
    try waitForHoverContains(allocator, &lsp, hover_params, "Custom module README hover works", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: import module-doc hover works for a module file larger than the old 128KB cap" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    const mod_dir_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "biglib" });
    defer allocator.free(mod_dir_abs);
    std.Io.Dir.createDirAbsolute(std.testing.io, mod_dir_abs, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, mod_dir_abs) catch {};

    // A module file whose leading doc comment is genuine, but whose TOTAL size
    // exceeds the old 128KB read cap (`fileReadAlloc`/`readFileAlloc` used to
    // fail outright past that limit, silently falling through to an empty
    // hover instead of showing the leading doc -- found via a real
    // self-hosted compiler module, `selfhost/codegen/codegen.fn`, which is
    // itself well past 128KB).
    const big_abs = try std.fs.path.join(allocator, &[_][]const u8{ mod_dir_abs, "big.fn" });
    defer allocator.free(big_abs);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, big_abs, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "// A big module that exceeds the old 128KB read cap.\n");
        var i: usize = 0;
        while (i < 5000) : (i += 1) {
            try f.writeStreamingAll(std.testing.io, "fun pad_filler() num { ret 0; }\n");
        }
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp biglib.big;\n\n" ++
        "fun main() {\n" ++
        "  ret;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-big-module-hover.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos = try findPosition(doc_text, "biglib.big", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + @as(i64, @intCast("biglib.".len)) },
    );
    defer allocator.free(hover_params);

    try waitForHoverContains(allocator, &lsp, hover_params, "A big module that exceeds the old 128KB read cap", 30000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: dot-shorthand hover on every plain enum variant shows 'See also', not just some" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const defs_text =
        "pub enum Kind {\n" ++
        "  First,\n" ++
        "  Second,\n" ++
        "}\n";
    const defs_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "fls_e2e_enum_seealso_defs.fn" });
    defer allocator.free(defs_abs);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, defs_abs, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, defs_text);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, defs_abs) catch {};

    const doc_text =
        "imp fls_e2e_enum_seealso_defs;\n\n" ++
        "fun describe(Kind k) str {\n" ++
        "  fit k {\n" ++
        "    .First -> { ret \"a\"; }\n" ++
        "    .Second -> { ret \"b\"; }\n" ++
        "  }\n" ++
        "}\n";
    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-enum-seealso-main.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Both bare dot-shorthand variants -- the FIRST one declared (`First`, which
    // resolves via the early "enum dot-shorthand hover" fast path in
    // handleHover) and the SECOND (`Second`) -- must both show a "See also"
    // link back to the enum, not just whichever one happens to resolve
    // through a later fallback path that already called
    // appendSeeAlsoForSymbol.
    const first_pos = try findPosition(doc_text, ".First ->", 0);
    const first_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, first_pos.line, first_pos.col + 1 },
    );
    defer allocator.free(first_params);
    try waitForHoverContains(allocator, &lsp, first_params, "See also", 30000);

    const second_pos = try findPosition(doc_text, ".Second ->", 0);
    const second_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, second_pos.line, second_pos.col + 1 },
    );
    defer allocator.free(second_params);
    try waitForHoverContains(allocator, &lsp, second_params, "See also", 30000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: typing with CRLF positions stays consistent" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, doc_abs) catch {};
    {
        const f = try std.Io.Dir.createFileAbsolute(std.testing.io, doc_abs, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, doc_text);
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var ws_res = try lsp.waitResponse(ws_id, 60000); // first `workspace/symbol` call lazily triggers the full-workspace scan (see indexWorkspace)
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

test "fls e2e: locals inside a test block are indexed for hover" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun make_count() num {\n" ++
        "  ret 5;\n" ++
        "}\n\n" ++
        "test \"counts things\" {\n" ++
        "  let n = make_count();\n" ++
        "  assert n == 5, \"expected 5\";\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-test-block-locals.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos = try findPosition(doc_text, "let n", 0);
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
    try expectHoverContains(allocator, hover_val, "num n");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: hover on `self` inside an impl method shows a pointer type" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound User {\n" ++
        "  num id;\n" ++
        "}\n\n" ++
        "impl User {\n" ++
        "  get_id() num {\n" ++
        "    ret self.id;\n" ++
        "  }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-self-hover.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // `self` is always an implicit pointer to the receiver compound (the
    // codegen emits `<Type>* self` as the first argument), so hovering over
    // it must render the pointer star just like an explicit `User* u` param.
    const self_pos = try findPosition(doc_text, "ret self.id", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, self_pos.line, self_pos.col + @as(i64, @intCast("ret ".len)) },
    );
    defer allocator.free(hover_params);
    const hover_id = try lsp.request("textDocument/hover", hover_params);
    // This hover is the only request the test issues, so (unlike most other
    // hover tests here, which warm up the workspace index via an earlier
    // completion/definition call first) it alone pays the full first-request
    // workspace-indexing cost; give it more headroom than the usual 15000ms.
    var hover_res = try lsp.waitResponse(hover_id, 45000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "User* self");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: for range loop locals support" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
        .{ doc_uri, comp_p_pos.line, comp_p_pos.col + 4 },
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
        .{ doc_uri, comp_p_pos.line, comp_p_pos.col + 4 },
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

test "fls e2e: signatureHelp specializes generic calls" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n\n" ++
        "fun first<T, U>(T a, U b) T {\n" ++
        "  _ = b;\n" ++
        "  ret a;\n" ++
        "}\n\n" ++
        "fun second<T, U>(T a, U b) U {\n" ++
        "  _ = a;\n" ++
        "  ret b;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  second(5, \"ok\"\n" ++
        "  second<num, str>(1, \"z\"\n" ++
        "  first<Box<num>, str>(Box<num>{v = 2}, \"q\"\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-sighelp-generic.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Implicit generic inference from literal arguments.
    const implicit_pos = try findPosition(doc_text, "second(5, \"ok\"", 0);
    const implicit_sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, implicit_pos.line, implicit_pos.col + @as(i64, @intCast("second(5, ".len)) },
    );
    defer allocator.free(implicit_sig_params);
    const implicit_sig_id = try lsp.request("textDocument/signatureHelp", implicit_sig_params);
    var implicit_sig_res = try lsp.waitResponse(implicit_sig_id, 15000);
    defer implicit_sig_res.deinit();
    const implicit_sig_val = try jsonResultFromResponseObj(implicit_sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, implicit_sig_val, "second<num, str>");
    try expectSignatureHelpHasParameter(allocator, implicit_sig_val, "num a");
    try expectSignatureHelpHasParameter(allocator, implicit_sig_val, "str b");
    try expectSignatureHelpActiveParameter(allocator, implicit_sig_val, 1);

    // Explicit type args should specialize signature label and params.
    const explicit_pos = try findPosition(doc_text, "second<num, str>(1, \"z\"", 0);
    const explicit_sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, explicit_pos.line, explicit_pos.col + @as(i64, @intCast("second<num, str>(1, ".len)) },
    );
    defer allocator.free(explicit_sig_params);
    const explicit_sig_id = try lsp.request("textDocument/signatureHelp", explicit_sig_params);
    var explicit_sig_res = try lsp.waitResponse(explicit_sig_id, 15000);
    defer explicit_sig_res.deinit();
    const explicit_sig_val = try jsonResultFromResponseObj(explicit_sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, explicit_sig_val, "second<num, str>");
    try expectSignatureHelpHasParameter(allocator, explicit_sig_val, "num a");
    try expectSignatureHelpHasParameter(allocator, explicit_sig_val, "str b");
    try expectSignatureHelpActiveParameter(allocator, explicit_sig_val, 1);

    const nested_pos = try findPosition(doc_text, "first<Box<num>, str>(Box<num>{v = 2}, \"q\"", 0);
    const nested_sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, nested_pos.line, nested_pos.col + @as(i64, @intCast("first<Box<num>, str>(Box<num>{v = 2}, ".len)) },
    );
    defer allocator.free(nested_sig_params);
    const nested_sig_id = try lsp.request("textDocument/signatureHelp", nested_sig_params);
    var nested_sig_res = try lsp.waitResponse(nested_sig_id, 15000);
    defer nested_sig_res.deinit();
    const nested_sig_val = try jsonResultFromResponseObj(nested_sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, nested_sig_val, "first<Box<num>, str>");
    try expectSignatureHelpHasParameter(allocator, nested_sig_val, "Box<num> a");
    try expectSignatureHelpHasParameter(allocator, nested_sig_val, "str b");
    try expectSignatureHelpActiveParameter(allocator, nested_sig_val, 1);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: array params appear in hover and signatureHelp" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
        "}\n\n" ++
        "fun sum(num[] values, dec scale) num {\n" ++
        "  _ = scale;\n" ++
        "  ret values[0];\n" ++
        "}\n\n" ++
        "fun head(Point[] points) Point {\n" ++
        "  ret points[0];\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  num[] nums = [1, 2, 3];\n" ++
        "  Point[] pts = [Point{x = 1}, Point{x = 2}];\n" ++
        "  sum(nums, 1.5\n" ++
        "  head(pts\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-array-params.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const sum_hover_pos = try findPosition(doc_text, "fun sum", 0);
    const sum_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, sum_hover_pos.line, sum_hover_pos.col + 4 },
    );
    defer allocator.free(sum_hover_params);
    const sum_hover_id = try lsp.request("textDocument/hover", sum_hover_params);
    var sum_hover_res = try lsp.waitResponse(sum_hover_id, 15000);
    defer sum_hover_res.deinit();
    const sum_hover_val = try jsonResultFromResponseObj(sum_hover_res.parsed.value.object);
    try expectHoverContains(allocator, sum_hover_val, "sum(num[] values, dec scale)");

    const sum_call_pos = try findPosition(doc_text, "sum(nums, 1.5", 0);
    const sum_sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, sum_call_pos.line, sum_call_pos.col + @as(i64, @intCast("sum(nums, ".len)) },
    );
    defer allocator.free(sum_sig_params);
    const sum_sig_id = try lsp.request("textDocument/signatureHelp", sum_sig_params);
    var sum_sig_res = try lsp.waitResponse(sum_sig_id, 15000);
    defer sum_sig_res.deinit();
    const sum_sig_val = try jsonResultFromResponseObj(sum_sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, sum_sig_val, "sum(num[] values, dec scale)");
    try expectSignatureHelpHasParameter(allocator, sum_sig_val, "num[] values");
    try expectSignatureHelpHasParameter(allocator, sum_sig_val, "dec scale");
    try expectSignatureHelpActiveParameter(allocator, sum_sig_val, 1);

    const head_call_pos = try findPosition(doc_text, "head(pts", 0);
    const head_sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, head_call_pos.line, head_call_pos.col + @as(i64, @intCast("head(".len)) },
    );
    defer allocator.free(head_sig_params);
    const head_sig_id = try lsp.request("textDocument/signatureHelp", head_sig_params);
    var head_sig_res = try lsp.waitResponse(head_sig_id, 15000);
    defer head_sig_res.deinit();
    const head_sig_val = try jsonResultFromResponseObj(head_sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, head_sig_val, "head(Point[] points)");
    try expectSignatureHelpHasParameter(allocator, head_sig_val, "Point[] points");
    try expectSignatureHelpActiveParameter(allocator, head_sig_val, 0);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: aliased stdlib inference and option members" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.math as m;\n" ++
        "imp std.rand as r;\n" ++
        "imp std.option;\n\n" ++
        "compound Person<T> {\n" ++
        "  T name;\n" ++
        "  num age;\n" ++
        "  Option<str> nickname;\n" ++
        "}\n\n" ++
        "impl Person<T> {\n" ++
        "  new(T name, num age) Person<T> {\n" ++
        "    ret Person{name = name, age = age, nickname = some(\"\")};\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  let root = m.sqrt_dec(4);\n" ++
        "  r.Rand rand = r.rand_init(42);\n" ++
        "  let flip = rand.chance(0.5);\n" ++
        "  Person<str> p;\n" ++
        "  p = p.new(\"Alice\", 30);\n" ++
        "  p.nickname = some(\"Ally\");\n" ++
        "  let nick = p.nickname.unwrap_or(\"No nickname\");\n" ++
        "  p.\n" ++
        "  p.nickname.unwrap_or(\"Alias\"\n" ++
        "  root\n" ++
        "  flip\n" ++
        "  nick\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-aliased-stdlib-option.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

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
    const comp_val = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_val, "name");
    try expectCompletionHasLabel(allocator, comp_val, "age");
    try expectCompletionHasLabel(allocator, comp_val, "nickname");
    try expectCompletionLabelDetailContains(allocator, comp_val, "nickname", "Option<str>");

    const sig_pos = try findPosition(doc_text, "p.nickname.unwrap_or(\"Alias\"", 0);
    const sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, sig_pos.line, sig_pos.col + @as(i64, @intCast("p.nickname.unwrap_or(".len)) + 1 },
    );
    defer allocator.free(sig_params);
    const sig_id = try lsp.request("textDocument/signatureHelp", sig_params);
    var sig_res = try lsp.waitResponse(sig_id, 15000);
    defer sig_res.deinit();
    const sig_val = try jsonResultFromResponseObj(sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, sig_val, "unwrap_or(str fallback)");
    try expectSignatureHelpHasParameter(allocator, sig_val, "str fallback");
    try expectSignatureHelpActiveParameter(allocator, sig_val, 0);

    const Case = struct { needle: []const u8, expect: []const u8 };
    const hover_cases = [_]Case{
        .{ .needle = "  root\n", .expect = "dec root" },
        .{ .needle = "  flip\n", .expect = "bin flip" },
        .{ .needle = "  nick\n", .expect = "str nick" },
    };

    for (hover_cases) |cinfo| {
        const pos = try findPosition(doc_text, cinfo.needle, 0);
        const hover_params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + 2 },
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

test "fls e2e: builtin sizeof completion + hover + signatureHelp" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

test "fls e2e: async/await completion details + hover + signatureHelp" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound Worker {\n" ++
        "  num value;\n" ++
        "}\n\n" ++
        "impl Worker {\n" ++
        "  async inc(num by) num {\n" ++
        "    self.value += by;\n" ++
        "    ret self.value;\n" ++
        "  }\n" ++
        "}\n\n" ++
        "async fun main() num {\n" ++
        "  Worker w;\n" ++
        "  a;\n" ++
        "  aw;\n" ++
        "  await w.inc(1);\n" ++
        "  w.\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-async-await.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Completion should include async/await with contextual detail.
    const a_pos = try findPosition(doc_text, "a;", 0);
    const a_comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, a_pos.line, a_pos.col + 1 },
    );
    defer allocator.free(a_comp_params);
    const a_comp_id = try lsp.request("textDocument/completion", a_comp_params);
    var a_comp_res = try lsp.waitResponse(a_comp_id, 15000);
    defer a_comp_res.deinit();
    const a_comp_val = try jsonResultFromResponseObj(a_comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, a_comp_val, "async");
    try expectCompletionLabelDetailContains(allocator, a_comp_val, "async", "declare async");

    const aw_pos = try findPosition(doc_text, "aw;", 0);
    const aw_comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, aw_pos.line, aw_pos.col + 2 },
    );
    defer allocator.free(aw_comp_params);
    const aw_comp_id = try lsp.request("textDocument/completion", aw_comp_params);
    var aw_comp_res = try lsp.waitResponse(aw_comp_id, 15000);
    defer aw_comp_res.deinit();
    const aw_comp_val = try jsonResultFromResponseObj(aw_comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, aw_comp_val, "await");
    try expectCompletionLabelDetailContains(allocator, aw_comp_val, "await", "await async call");

    // Hover on `await` keyword should describe async-only usage.
    const await_pos = try findPosition(doc_text, "await w.inc", 0);
    const await_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, await_pos.line, await_pos.col + 2 },
    );
    defer allocator.free(await_hover_params);
    const await_hover_id = try lsp.request("textDocument/hover", await_hover_params);
    var await_hover_res = try lsp.waitResponse(await_hover_id, 15000);
    defer await_hover_res.deinit();
    const await_hover_val = try jsonResultFromResponseObj(await_hover_res.parsed.value.object);
    try expectHoverContains(allocator, await_hover_val, "only valid inside `async` functions");

    // Dot completion should include async method signatures in detail.
    const dot_pos = try findPosition(doc_text, "  w.\n", 0);
    const dot_comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, dot_pos.line, dot_pos.col + 4 },
    );
    defer allocator.free(dot_comp_params);
    const dot_comp_id = try lsp.request("textDocument/completion", dot_comp_params);
    var dot_comp_res = try lsp.waitResponse(dot_comp_id, 15000);
    defer dot_comp_res.deinit();
    const dot_comp_val = try jsonResultFromResponseObj(dot_comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, dot_comp_val, "inc");
    try expectCompletionLabelDetailContains(allocator, dot_comp_val, "inc", "async inc(num by) num");

    // Hover and signatureHelp on async member call should include async in signature.
    const inc_use = try findPosition(doc_text, "w.inc(1)", 0);
    const inc_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, inc_use.line, inc_use.col + 3 },
    );
    defer allocator.free(inc_hover_params);
    const inc_hover_id = try lsp.request("textDocument/hover", inc_hover_params);
    var inc_hover_res = try lsp.waitResponse(inc_hover_id, 15000);
    defer inc_hover_res.deinit();
    const inc_hover_val = try jsonResultFromResponseObj(inc_hover_res.parsed.value.object);
    try expectHoverContains(allocator, inc_hover_val, "async inc(num by) num");

    const sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, inc_use.line, inc_use.col + 6 },
    );
    defer allocator.free(sig_params);
    const sig_id = try lsp.request("textDocument/signatureHelp", sig_params);
    var sig_res = try lsp.waitResponse(sig_id, 15000);
    defer sig_res.deinit();
    const sig_val = try jsonResultFromResponseObj(sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, sig_val, "async inc(num by) num");
    try expectSignatureHelpActiveParameter(allocator, sig_val, 0);

    // Definition on async member call should jump to method declaration.
    const inc_def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, inc_use.line, inc_use.col + 3 },
    );
    defer allocator.free(inc_def_params);
    const inc_def_id = try lsp.request("textDocument/definition", inc_def_params);
    var inc_def_res = try lsp.waitResponse(inc_def_id, 15000);
    defer inc_def_res.deinit();
    const inc_def_val = try jsonResultFromResponseObj(inc_def_res.parsed.value.object);

    const inc_decl = try findPosition(doc_text, "async inc(num by) num", 0);
    try expectDefinitionPointsTo(allocator, inc_def_val, doc_uri, inc_decl.line, inc_decl.col + @as(i64, @intCast("async ".len)));

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: async diagnostics map to code actions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "async fun inc(num x) num { ret x + 1; }\n" ++
        "async fun missing() num {\n" ++
        "  num y = inc(1);\n" ++
        "  ret y;\n" ++
        "}\n" ++
        "fun plain() num {\n" ++
        "  num z = await inc(1);\n" ++
        "  ret z;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-codeaction-async.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const missing_stmt = try findPosition(doc_text, "num y = inc(1);", 0);
    const missing_start = missing_stmt.col + @as(i64, @intCast("num y = ".len));
    const missing_end = missing_start + @as(i64, @intCast("inc".len));

    const await_stmt = try findPosition(doc_text, "await inc(1);", 0);
    const await_start = await_stmt.col;
    const await_end = await_start + @as(i64, @intCast("await".len));

    const code_action_params = try std.fmt.allocPrint(
        allocator,
        "{{" ++
            "\"textDocument\":{{\"uri\":\"{s}\"}}," ++
            "\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}," ++
            "\"context\":{{\"diagnostics\":[" ++
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1,\"code\":\"async_call_requires_await\",\"message\":\"diagnostic message intentionally not matched by text\"}}," ++
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1,\"code\":\"await_outside_async_function\",\"message\":\"diagnostic message intentionally not matched by text\"}}" ++
            "]}}" ++
            "}}",
        .{
            doc_uri,
            missing_stmt.line,
            missing_start,
            missing_stmt.line,
            missing_end,
            missing_stmt.line,
            missing_start,
            missing_stmt.line,
            missing_end,
            await_stmt.line,
            await_start,
            await_stmt.line,
            await_end,
        },
    );
    defer allocator.free(code_action_params);

    const ca_id = try lsp.request("textDocument/codeAction", code_action_params);
    var ca_res = try lsp.waitResponse(ca_id, 15000);
    defer ca_res.deinit();
    const ca_val = try jsonResultFromResponseObj(ca_res.parsed.value.object);

    try expectCodeActionHasTitleWithNewText(allocator, ca_val, "Insert 'await'", "await ");
    try expectCodeActionHasTitleWithNewText(allocator, ca_val, "Mark enclosing function async", "async ");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let await parity hover completion definition signatureHelp" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound User {\n" ++
        "  num id;\n" ++
        "  num age;\n" ++
        "}\n\n" ++
        "async fun fetch_user(num id) User {\n" ++
        "  User u;\n" ++
        "  u.id = id;\n" ++
        "  u.age = 42;\n" ++
        "  ret u;\n" ++
        "}\n\n" ++
        "async fun main() num {\n" ++
        "  let out = await fetch_user(7);\n" ++
        "  out.\n" ++
        "  num age = out.age;\n" ++
        "  ret age;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-await-parity.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const let_pos = try findPosition(doc_text, "let out = await fetch_user", 0);
    const out_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, let_pos.line, let_pos.col + 5 },
    );
    defer allocator.free(out_hover_params);
    const out_hover_id = try lsp.request("textDocument/hover", out_hover_params);
    var out_hover_res = try lsp.waitResponse(out_hover_id, 15000);
    defer out_hover_res.deinit();
    const out_hover_val = try jsonResultFromResponseObj(out_hover_res.parsed.value.object);
    try expectHoverContains(allocator, out_hover_val, "User out");

    const out_dot_pos = try findPosition(doc_text, "  out.\n", 0);
    const out_comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, out_dot_pos.line, out_dot_pos.col + @as(i64, @intCast("  out.".len)) },
    );
    defer allocator.free(out_comp_params);
    const out_comp_id = try lsp.request("textDocument/completion", out_comp_params);
    var out_comp_res = try lsp.waitResponse(out_comp_id, 15000);
    defer out_comp_res.deinit();
    const out_comp_val = try jsonResultFromResponseObj(out_comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, out_comp_val, "id");
    try expectCompletionHasLabel(allocator, out_comp_val, "age");

    const call_pos = try findPosition(doc_text, "fetch_user(7)", 0);
    const def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + 2 },
    );
    defer allocator.free(def_params);
    const def_id = try lsp.request("textDocument/definition", def_params);
    var def_res = try lsp.waitResponse(def_id, 15000);
    defer def_res.deinit();
    const def_val = try jsonResultFromResponseObj(def_res.parsed.value.object);
    const decl_pos = try findPosition(doc_text, "fetch_user(num id)", 0);
    try expectDefinitionPointsTo(allocator, def_val, doc_uri, decl_pos.line, decl_pos.col + 2);

    const sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + @as(i64, @intCast("fetch_user(".len)) },
    );
    defer allocator.free(sig_params);
    const sig_id = try lsp.request("textDocument/signatureHelp", sig_params);
    var sig_res = try lsp.waitResponse(sig_id, 15000);
    defer sig_res.deinit();
    const sig_val = try jsonResultFromResponseObj(sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, sig_val, "async fun fetch_user(num id) User");
    try expectSignatureHelpActiveParameter(allocator, sig_val, 0);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let await pointer chain inference" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num {\n" ++
        "    ret self.base + x;\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun ptr(Box<AsyncCounter>* b) Box<AsyncCounter>* {\n" ++
        "  ret b;\n" ++
        "}\n\n" ++
        "async fun main() num {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  let b = Box{v = q};\n" ++
        "  let boxed = *ptr(&b);\n" ++
        "  let out = await (*ptr(&b)).v.add(1);\n" ++
        "  let out2 = await (*ptr(&b)).v.add(1);\n" ++
        "  _ = boxed;\n" ++
        "  ret out + out2;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-await-pointer-chain.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const b_pos = try findPosition(doc_text, "let b = Box{v = q}", 0);
    const b_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, b_pos.line, b_pos.col + 4 },
    );
    defer allocator.free(b_hover_params);
    const b_hover_id = try lsp.request("textDocument/hover", b_hover_params);
    var b_hover_res = try lsp.waitResponse(b_hover_id, 15000);
    defer b_hover_res.deinit();
    const b_hover_val = try jsonResultFromResponseObj(b_hover_res.parsed.value.object);
    try expectHoverContains(allocator, b_hover_val, "Box<AsyncCounter> b");

    const boxed_pos = try findPosition(doc_text, "let boxed = *ptr(&b)", 0);
    const boxed_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, boxed_pos.line, boxed_pos.col + 5 },
    );
    defer allocator.free(boxed_hover_params);
    const boxed_hover_id = try lsp.request("textDocument/hover", boxed_hover_params);
    var boxed_hover_res = try lsp.waitResponse(boxed_hover_id, 15000);
    defer boxed_hover_res.deinit();
    const boxed_hover_val = try jsonResultFromResponseObj(boxed_hover_res.parsed.value.object);
    try expectHoverContains(allocator, boxed_hover_val, "Box<AsyncCounter> boxed");

    const out_pos = try findPosition(doc_text, "let out = await (*ptr(&b)).v.add", 0);
    const out_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, out_pos.line, out_pos.col + 5 },
    );
    defer allocator.free(out_hover_params);
    const out_hover_id = try lsp.request("textDocument/hover", out_hover_params);
    var out_hover_res = try lsp.waitResponse(out_hover_id, 15000);
    defer out_hover_res.deinit();
    const out_hover_val = try jsonResultFromResponseObj(out_hover_res.parsed.value.object);
    try expectHoverContains(allocator, out_hover_val, "num out");

    const out2_pos = try findPosition(doc_text, "let out2 = await (*ptr(&b)).v.add", 0);
    const out2_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, out2_pos.line, out2_pos.col + 5 },
    );
    defer allocator.free(out2_hover_params);
    const out2_hover_id = try lsp.request("textDocument/hover", out2_hover_params);
    var out2_hover_res = try lsp.waitResponse(out2_hover_id, 15000);
    defer out2_hover_res.deinit();
    const out2_hover_val = try jsonResultFromResponseObj(out2_hover_res.parsed.value.object);
    try expectHoverContains(allocator, out2_hover_val, "num out2");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: std.channel async forwarding completion + hover" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Ensure the workspace std.channel symbols are indexed for this session.
    const channel_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "stdlib", "std", "channel.fn" });
    defer allocator.free(channel_abs);
    const channel_src = blk: {
        var f = try std.Io.Dir.openFileAbsolute(std.testing.io, channel_abs, .{});
        defer f.close(std.testing.io);
        break :blk try blk2: {
            var _rb: [65536]u8 = undefined;
            var _fr = f.reader(std.testing.io, &_rb);
            break :blk2 _fr.interface.allocRemaining(allocator, .limited(1024 * 1024));
        };
    };
    defer allocator.free(channel_src);
    const channel_uri = try pathToFileUriAlloc(allocator, channel_abs);
    defer allocator.free(channel_uri);
    try lspOpenDoc(allocator, &lsp, channel_uri, 1, channel_src);

    const doc_text =
        "imp std.channel;\n\n" ++
        "async fun main() num {\n" ++
        "  Channel<num> src = channel_new_cap(0, 1);\n" ++
        "  Channel<num> other = channel_new_cap(0, 1);\n" ++
        "  Channel<num> dst = channel_new_cap(0, 1);\n" ++
        "  num idx = -1;\n" ++
        "  src.\n" ++
        "  await src.forward_one_to_async(&dst, 20);\n" ++
        "  await src.select_forward_one_to_async(&other, &dst, 20, &idx);\n" ++
        "  ret idx;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-channel-forwarding-async.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const dot_pos = try findPosition(doc_text, "  src.\n", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, dot_pos.line, dot_pos.col + @as(i64, @intCast("  src.".len)) },
    );
    defer allocator.free(comp_params);

    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_val = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_val, "forward_one_to_async");
    try expectCompletionHasLabel(allocator, comp_val, "select_forward_one_to_async");

    const channel_type_pos = try findPosition(doc_text, "Channel<num> src", 0);
    const channel_type_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, channel_type_pos.line, channel_type_pos.col + 2 },
    );
    defer allocator.free(channel_type_hover_params);
    try waitForHoverContains(allocator, &lsp, channel_type_hover_params, "compound Channel<num>", 15000);

    const fwd_pos = try findPosition(doc_text, "forward_one_to_async", 0);
    const fwd_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, fwd_pos.line, fwd_pos.col + 2 },
    );
    defer allocator.free(fwd_hover_params);
    try waitForHoverContains(allocator, &lsp, fwd_hover_params, "forward_one_to_async", 15000);

    const select_fwd_pos = try findPosition(doc_text, "select_forward_one_to_async", 0);
    const select_fwd_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, select_fwd_pos.line, select_fwd_pos.col + 2 },
    );
    defer allocator.free(select_fwd_hover_params);
    try waitForHoverContains(allocator, &lsp, select_fwd_hover_params, "select_forward_one_to_async", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let inference from imported generic call" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.channel;\n\n" ++
        "fun main() {\n" ++
        "  let ticks = channel_new_cap(0, 4);\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-infer-imported-generic.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const ticks_pos = try findPosition(doc_text, "let ticks", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, ticks_pos.line, ticks_pos.col + 5 },
    );
    defer allocator.free(hover_params);

    try waitForHoverContains(allocator, &lsp, hover_params, "Channel<num> ticks", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let inference from chained member initializers" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.channel;\n\n" ++
        "fun main() {\n" ++
        "  let src = channel_new_cap(0, 4);\n" ++
        "  let wait_a = src.get_select_wait_slice_ms();\n" ++
        "  let wait_b = channel_new_cap(0, 4).get_select_wait_slice_ms();\n" ++
        "  let backoff_a = src.select_wait_backoff_steps;\n" ++
        "  let backoff_b = channel_new_cap(0, 4).select_wait_backoff_steps;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-infer-chained-member.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const src_pos = try findPosition(doc_text, "let src", 0);
    const src_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, src_pos.line, src_pos.col + 5 },
    );
    defer allocator.free(src_hover_params);
    try waitForHoverContains(allocator, &lsp, src_hover_params, "Channel<num> src", 15000);

    const wait_a_pos = try findPosition(doc_text, "let wait_a", 0);
    const wait_a_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, wait_a_pos.line, wait_a_pos.col + 5 },
    );
    defer allocator.free(wait_a_hover_params);
    try waitForHoverContains(allocator, &lsp, wait_a_hover_params, "num wait_a", 15000);

    const wait_b_pos = try findPosition(doc_text, "let wait_b", 0);
    const wait_b_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, wait_b_pos.line, wait_b_pos.col + 5 },
    );
    defer allocator.free(wait_b_hover_params);
    try waitForHoverContains(allocator, &lsp, wait_b_hover_params, "num wait_b", 15000);

    const backoff_a_pos = try findPosition(doc_text, "let backoff_a", 0);
    const backoff_a_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, backoff_a_pos.line, backoff_a_pos.col + 5 },
    );
    defer allocator.free(backoff_a_hover_params);
    try waitForHoverContains(allocator, &lsp, backoff_a_hover_params, "num backoff_a", 15000);

    const backoff_b_pos = try findPosition(doc_text, "let backoff_b", 0);
    const backoff_b_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, backoff_b_pos.line, backoff_b_pos.col + 5 },
    );
    defer allocator.free(backoff_b_hover_params);
    try waitForHoverContains(allocator, &lsp, backoff_b_hover_params, "num backoff_b", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let inference await async call with address arg" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.channel;\n\n" ++
        "async fun main() {\n" ++
        "  let ch = channel_new_cap(0, 1);\n" ++
        "  num out = 0;\n" ++
        "  let rc = await ch.recv_timeout_into_async(&out, 10);\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-infer-await-address-arg.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const rc_pos = try findPosition(doc_text, "let rc", 0);
    const rc_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, rc_pos.line, rc_pos.col + 5 },
    );
    defer allocator.free(rc_hover_params);
    try waitForHoverContains(allocator, &lsp, rc_hover_params, "num rc", 15000);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: references and rename baseline" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun add_one(num x) num { ret x + 1; }\n" ++
        "fun main() num {\n" ++
        "  num a = add_one(1);\n" ++
        "  num b = add_one(2);\n" ++
        "  ret a + b;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-references-rename-baseline.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const decl_pos = try findPosition(doc_text, "add_one(num x)", 0);
    const call1_pos = try findPosition(doc_text, "add_one(1)", 0);
    const call2_pos = try findPosition(doc_text, "add_one(2)", 0);

    const refs_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call1_pos.line, call1_pos.col + 2 },
    );
    defer allocator.free(refs_params);
    const refs_id = try lsp.request("textDocument/references", refs_params);
    var refs_res = try lsp.waitResponse(refs_id, 60000); // first call to `references` lazily triggers the full-workspace scan (see indexWorkspace)
    defer refs_res.deinit();
    const refs_val = try jsonResultFromResponseObj(refs_res.parsed.value.object);
    try expectLocationsContain(allocator, refs_val, doc_uri, decl_pos.line, decl_pos.col + 2);
    try expectLocationsContain(allocator, refs_val, doc_uri, call1_pos.line, call1_pos.col + 2);
    try expectLocationsContain(allocator, refs_val, doc_uri, call2_pos.line, call2_pos.col + 2);

    const rename_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"sum_one\"}}",
        .{ doc_uri, call1_pos.line, call1_pos.col + 2 },
    );
    defer allocator.free(rename_params);
    const rename_id = try lsp.request("textDocument/rename", rename_params);
    var rename_res = try lsp.waitResponse(rename_id, 15000);
    defer rename_res.deinit();
    const rename_val = try jsonResultFromResponseObj(rename_res.parsed.value.object);
    try expectRenameEditCountForUri(allocator, rename_val, doc_uri, "sum_one", 3);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: references and rename with let await async calls" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound User { num id; }\n" ++
        "async fun fetch_user(num id) User {\n" ++
        "  User u;\n" ++
        "  u.id = id;\n" ++
        "  ret u;\n" ++
        "}\n" ++
        "async fun main() num {\n" ++
        "  let a = await fetch_user(1);\n" ++
        "  let b = await fetch_user(2);\n" ++
        "  ret a.id + b.id;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-references-rename-async-let-await.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const decl_pos = try findPosition(doc_text, "fetch_user(num id)", 0);
    const call1_pos = try findPosition(doc_text, "fetch_user(1)", 0);
    const call2_pos = try findPosition(doc_text, "fetch_user(2)", 0);

    const refs_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call1_pos.line, call1_pos.col + 2 },
    );
    defer allocator.free(refs_params);
    const refs_id = try lsp.request("textDocument/references", refs_params);
    var refs_res = try lsp.waitResponse(refs_id, 60000); // first call to `references` lazily triggers the full-workspace scan (see indexWorkspace)
    defer refs_res.deinit();
    const refs_val = try jsonResultFromResponseObj(refs_res.parsed.value.object);
    try expectLocationsContain(allocator, refs_val, doc_uri, decl_pos.line, decl_pos.col + 2);
    try expectLocationsContain(allocator, refs_val, doc_uri, call1_pos.line, call1_pos.col + 2);
    try expectLocationsContain(allocator, refs_val, doc_uri, call2_pos.line, call2_pos.col + 2);

    const rename_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"load_user\"}}",
        .{ doc_uri, call1_pos.line, call1_pos.col + 2 },
    );
    defer allocator.free(rename_params);
    const rename_id = try lsp.request("textDocument/rename", rename_params);
    var rename_res = try lsp.waitResponse(rename_id, 15000);
    defer rename_res.deinit();
    const rename_val = try jsonResultFromResponseObj(rename_res.parsed.value.object);
    try expectRenameEditCountForUri(allocator, rename_val, doc_uri, "load_user", 3);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: warning ids completion for allow and expect" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const slow_timeout_ms = 30000;

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun main() {\n" ++
        "  allow f\n" ++
        "  expect r\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-warning-ids.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Wait for didOpen diagnostics for this exact document so completion timing
    // is not coupled to unrelated workspace diagnostics.
    {
        const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + slow_timeout_ms;
        var saw_doc_diagnostics = false;

        while (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) < deadline_ms and !saw_doc_diagnostics) {
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
            if (uri_val != .string) continue;

            if (std.mem.eql(u8, uri_val.string, doc_uri)) {
                saw_doc_diagnostics = true;
            }
        }

        try std.testing.expect(saw_doc_diagnostics);
    }

    const allow_pos = try findPosition(doc_text, "allow f", 0);
    const allow_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, allow_pos.line, allow_pos.col + @as(i64, @intCast("allow f".len)) },
    );
    defer allocator.free(allow_params);
    const allow_id = try lsp.request("textDocument/completion", allow_params);
    var allow_res = try lsp.waitResponse(allow_id, slow_timeout_ms);
    defer allow_res.deinit();
    const allow_val = try jsonResultFromResponseObj(allow_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, allow_val, "fit_non_exhaustive");
    try expectCompletionHasLabel(allocator, allow_val, "fit_unreachable_branch");
    try expectCompletionHasLabel(allocator, allow_val, "unreachable_code");
    try expectCompletionHasLabel(allocator, allow_val, "assert_constant");
    try expectCompletionHasLabel(allocator, allow_val, "unused_variable");
    try expectCompletionHasLabel(allocator, allow_val, "unused_import");
    try expectCompletionHasLabel(allocator, allow_val, "unused_function");
    try expectCompletionHasLabel(allocator, allow_val, "unused_compound");

    const expect_pos = try findPosition(doc_text, "expect r", 0);
    const expect_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, expect_pos.line, expect_pos.col + @as(i64, @intCast("expect r".len)) },
    );
    defer allocator.free(expect_params);
    const expect_id = try lsp.request("textDocument/completion", expect_params);
    var expect_res = try lsp.waitResponse(expect_id, slow_timeout_ms);
    defer expect_res.deinit();
    const expect_val = try jsonResultFromResponseObj(expect_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, expect_val, "return_local_ptr");
    try expectCompletionHasLabel(allocator, expect_val, "fit_unreachable_branch");
    try expectCompletionHasLabel(allocator, expect_val, "unreachable_code");
    try expectCompletionHasLabel(allocator, expect_val, "assert_constant");
    try expectCompletionHasLabel(allocator, expect_val, "unused_variable");
    try expectCompletionHasLabel(allocator, expect_val, "unused_import");
    try expectCompletionHasLabel(allocator, expect_val, "unused_function");
    try expectCompletionHasLabel(allocator, expect_val, "unused_compound");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: publishDiagnostics includes warning from ID-tagged warning output" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + 15000;
    var saw_expected_warning = false;

    while (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) < deadline_ms and !saw_expected_warning) {
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

test "fls e2e: publishDiagnostics includes fit_non_exhaustive warning in diag-only mode" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  fit x {\n" ++
        "    true -> { printf(\"x was true\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fit-warning-diagnostics.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + 15000;
    var saw_expected_warning = false;

    while (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) < deadline_ms and !saw_expected_warning) {
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
            const code = dv.object.get("code") orelse continue;
            if (sev != .integer or msg != .string or code != .string) continue;
            if (sev.integer != 2) continue;

            if (std.mem.eql(u8, code.string, "fit_non_exhaustive") and
                std.mem.indexOf(u8, msg.string, "missing false branch") != null)
            {
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

test "fls e2e: publishDiagnostics includes unused_variable warning" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun main() void {\n" ++
        "  num value = 1;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-unused-variable-warning.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + 15000;
    var saw_expected_warning = false;

    while (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) < deadline_ms and !saw_expected_warning) {
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
            const code = dv.object.get("code") orelse continue;
            if (sev != .integer or msg != .string or code != .string) continue;
            if (sev.integer != 2) continue;

            if (std.mem.eql(u8, code.string, "unused_variable") and
                std.mem.indexOf(u8, msg.string, "unused variable 'value'") != null)
            {
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

test "fls e2e: publishDiagnostics includes unused_import warning" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.option;\n" ++
        "fun main() {\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-unused-import-warning.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + 15000;
    var saw_expected_warning = false;

    while (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) < deadline_ms and !saw_expected_warning) {
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
            const code = dv.object.get("code") orelse continue;
            if (sev != .integer or msg != .string or code != .string) continue;
            if (sev.integer != 2) continue;

            if (std.mem.eql(u8, code.string, "unused_import") and
                std.mem.indexOf(u8, msg.string, "unused import 'std.option'") != null)
            {
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

test "fls e2e: imported public function call suppresses unused_import warning" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    const helper_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, ".zig-cache", "fls_e2e_unused_import_public_function_helper.fn" });
    defer allocator.free(helper_abs);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, helper_abs, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
            "pub fun helper() num {\n" ++
                "  ret 1;\n" ++
                "}\n",
        );
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, helper_abs) catch {};

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp fls_e2e_unused_import_public_function_helper;\n" ++
        "fun main() {\n" ++
        "  num value = helper();\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-unused-import-public-function.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + 15000;
    var saw_expected_warning = false;
    var saw_unexpected_unused_import = false;
    var saw_unexpected_import_error = false;

    while (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) < deadline_ms and !saw_expected_warning and !saw_unexpected_unused_import and !saw_unexpected_import_error) {
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
            const code = dv.object.get("code");
            if (sev != .integer or msg != .string) continue;
            if (sev.integer != 2) continue;

            if (code) |code_val| {
                if (code_val == .string and std.mem.eql(u8, code_val.string, "unused_import")) {
                    saw_unexpected_unused_import = true;
                }
                if (code_val == .string and std.mem.eql(u8, code_val.string, "unused_variable") and
                    std.mem.indexOf(u8, msg.string, "unused variable 'value'") != null)
                {
                    saw_expected_warning = true;
                }
            }

            if (std.mem.indexOf(u8, msg.string, "Import file not found") != null) {
                saw_unexpected_import_error = true;
            }
        }
    }

    try std.testing.expect(saw_expected_warning);
    try std.testing.expect(!saw_unexpected_unused_import);
    try std.testing.expect(!saw_unexpected_import_error);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: publishDiagnostics suppresses expect unused_import after formatting" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "expect unused_import, \"tracked import until the API lands\";\n" ++
        "imp std.option;\n" ++
        "fun main() {\n" ++
        "  num value = 1;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-unused-import-expect.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const deadline_ms = @as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) + 15000;
    var saw_expected_warning = false;
    var saw_unexpected_unused_import = false;
    var saw_unexpected_expect_error = false;

    while (@as(i64, @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms))) < deadline_ms and !saw_expected_warning and !saw_unexpected_unused_import and !saw_unexpected_expect_error) {
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
            const code = dv.object.get("code");
            if (sev != .integer or msg != .string) continue;

            if (code) |code_val| {
                if (code_val == .string and std.mem.eql(u8, code_val.string, "unused_import")) {
                    saw_unexpected_unused_import = true;
                }
                if (code_val == .string and std.mem.eql(u8, code_val.string, "unused_variable") and
                    std.mem.indexOf(u8, msg.string, "unused variable 'value'") != null)
                {
                    saw_expected_warning = true;
                }
            }

            if (std.mem.indexOf(u8, msg.string, "expected warning 'unused_import' was not emitted") != null) {
                saw_unexpected_expect_error = true;
            }
        }
    }

    try std.testing.expect(saw_expected_warning);
    try std.testing.expect(!saw_unexpected_unused_import);
    try std.testing.expect(!saw_unexpected_expect_error);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: enum variant dot completion + hover" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

test "fls e2e: dot completion + definition find async impl methods across imported files" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    // Create a tiny multi-file project under `.zig-cache/` so import resolution matches
    // what fls does for in-editor unsaved buffers.
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache") catch {};

    const user_path = ".zig-cache/__fls_implsep_user.fn";
    const impl_path = ".zig-cache/__fls_implsep_user_impl.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, user_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, impl_path) catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, user_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
            "pub compound User {\n" ++
                "  str name;\n" ++
                "}\n",
        );
    }
    const impl_source =
        "imp __fls_implsep_user;\n\n" ++
        "impl User {\n" ++
        "  pub async wave_async_implsep() str {\n" ++
        "    ret self.name;\n" ++
        "  }\n" ++
        "}\n";

    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, impl_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, impl_source);
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp __fls_implsep_user;\n" ++
        "imp __fls_implsep_user_impl;\n\n" ++
        "async fun main() num {\n" ++
        "  User user;\n" ++
        "  user.name = \"Alice\";\n" ++
        "  User* u = &user;\n" ++
        "  let msg = await u.wave_async_implsep();\n" ++
        "  u.\n" ++
        "  ret 0;\n" ++
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

    // 45s (not the usual 5s): this is the first request the test issues
    // after opening the doc, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 45000);
    defer comp_res.deinit();
    try std.testing.expect(comp_res.parsed.value == .object);
    const comp_obj = comp_res.parsed.value.object;
    const result_val = try jsonResultFromResponseObj(comp_obj);

    // Expect method completion from `impl User` living in a different imported file.
    try expectCompletionHasLabel(allocator, result_val, "wave_async_implsep");
    try expectCompletionLabelDetailContains(allocator, result_val, "wave_async_implsep", "async wave_async_implsep() str");

    // Definition should jump from async member call to the imported impl method declaration.
    const call_pos = try findPosition(doc_text, "u.wave_async_implsep()", 0);
    const def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + @as(i64, @intCast("u.".len)) },
    );
    defer allocator.free(def_params);
    const def_id = try lsp.request("textDocument/definition", def_params);
    var def_res = try lsp.waitResponse(def_id, 15000);
    defer def_res.deinit();
    const def_val = try jsonResultFromResponseObj(def_res.parsed.value.object);

    const method_decl = try findPosition(impl_source, "wave_async_implsep() str", 0);
    try expectDefinitionPointsTo(allocator, def_val, impl_path, method_decl.line, method_decl.col);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: quirks across folders complete + missing methods diagnose" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache") catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/qaf/defs") catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/qaf/impls") catch {};

    const user_path = ".zig-cache/qaf/defs/user.fn";
    const greeter_path = ".zig-cache/qaf/defs/greeter.fn";
    const impl_ok_path = ".zig-cache/qaf/impls/user_greeter_ok.fn";
    const impl_bad_path = ".zig-cache/qaf/impls/user_greeter_bad.fn";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, user_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, greeter_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, impl_ok_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, impl_bad_path) catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, user_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
            "compound User {\n" ++
                "  str name;\n" ++
                "}\n",
        );
    }
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, greeter_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
            "pub quirk Greeter {\n" ++
                "  pub greet(str prefix) void;\n" ++
                "  pub bye() void;\n" ++
                "}\n",
        );
    }
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, impl_ok_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
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
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, impl_bad_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        // Intentionally missing `bye()`.
        try f.writeStreamingAll(std.testing.io, impl_bad_source);
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // --- 1) Completion for quirk/type names in an impl header.
    const doc_text_impl_header =
        "imp qaf.defs.user;\n" ++
        "imp qaf.defs.greeter;\n\n" ++
        "impl User as \n";

    const doc_uri_impl_header = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-qaf-impl-header.fn");
    defer allocator.free(doc_uri_impl_header);
    try lspOpenDoc(allocator, &lsp, doc_uri_impl_header, 1, doc_text_impl_header);

    const impl_pos = try findPosition(doc_text_impl_header, "impl User as ", 0);
    const comp_params_impl = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri_impl_header, impl_pos.line, impl_pos.col + @as(i64, @intCast("impl User as ".len)) },
    );
    defer allocator.free(comp_params_impl);

    try waitForCompletionLabel(allocator, &lsp, comp_params_impl, "Greeter", 15000);

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

    try waitForCompletionLabel(allocator, &lsp, comp_params_dot, "greet", 15000);
    try waitForCompletionLabel(allocator, &lsp, comp_params_dot, "bye", 15000);

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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    // 45s (not the usual 5s): this is the first request the test issues
    // after initialize, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const comp_id_0 = try lsp.request("textDocument/completion", comp_params_0);
    var comp_res_0 = try lsp.waitResponse(comp_id_0, 45000);
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // 45s (not the usual 5s): this is the first request the test issues
    // after initialize, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const id = try lsp.request("fun/doesNotExist", "{}");
    var res = try lsp.waitResponse(id, 45000);
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
        var res = try lsp.waitResponse(id, 60000); // first `workspace/symbol` call lazily triggers the full-workspace scan (see indexWorkspace)
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

test "fls e2e: format-on-save cache hit - warm save skips subprocess" {
    // Verifies the two key performance improvements:
    // 1. didOpen now runs -fmt-diag, so the format cache is warm before the user
    //    ever explicitly saves. The first explicit format request is a cache hit.
    // 2. After format runs, a second format with the same content is also a cache hit.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
        "  printf(\"hello\\n\");\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-save-perf.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const fmt_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"options\":{{\"tabSize\":2,\"insertSpaces\":true}}}}",
        .{doc_uri},
    );
    defer allocator.free(fmt_params);

    const io = std.testing.io;

    // Wait for the initial publishDiagnostics from didOpen.
    // This confirms the -fmt-diag subprocess has completed and warmed the format cache.
    {
        if (lsp.waitNotification("textDocument/publishDiagnostics", 15000)) |notif| {
            var n = notif;
            n.deinit();
        } else |_| {}
    }

    // --- First format after didOpen: should be a cache hit (no subprocess) ---
    const first_t0: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
    const fmt_id = try lsp.request("textDocument/formatting", fmt_params);
    var fmt_res = try lsp.waitResponse(fmt_id, 15000);
    defer fmt_res.deinit();
    const first_ms = @divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms) - first_t0;

    try std.testing.expect(fmt_res.parsed.value == .object);
    _ = try jsonResultFromResponseObj(fmt_res.parsed.value.object);
    std.debug.print("\n[perf] first format after didOpen (cache hit): {}ms\n", .{first_ms});

    // A cold subprocess takes ~300-1600 ms total (including server overhead).
    // A cache hit takes ~50-100 ms (1-2 poll cycles) locally. Threshold is
    // 280 ms -- comfortably above local cache-hit noise and shared CI
    // runners' extra jitter, while staying below the cold-subprocess floor
    // so this still catches a real cache-miss regression.
    try std.testing.expect(first_ms < 280);

    // --- Second format (identical content - must also be a cache hit) ---
    const warm_t0: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
    const fmt_id2 = try lsp.request("textDocument/formatting", fmt_params);
    var fmt_res2 = try lsp.waitResponse(fmt_id2, 5000);
    defer fmt_res2.deinit();
    const warm_ms = @divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms) - warm_t0;

    try std.testing.expect(fmt_res2.parsed.value == .object);
    _ = try jsonResultFromResponseObj(fmt_res2.parsed.value.object);
    std.debug.print("[perf] second format (cache hit): {}ms\n", .{warm_ms});
    try std.testing.expect(warm_ms < 280);

    // --- didSave immediately after format (the format-on-save pattern) ---
    // FLS should early-return because last_diag_ms is < 1500 ms ago.
    const save_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}",
        .{doc_uri},
    );
    defer allocator.free(save_params);

    try lsp.notify("textDocument/didSave", save_params);
    // Ping to confirm server stayed alive and responsive after the early-return save.
    const ping_t0: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
    const ping_id = try lsp.request("textDocument/formatting", fmt_params);
    var ping_res = try lsp.waitResponse(ping_id, 5000);
    defer ping_res.deinit();
    const ping_ms = @divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms) - ping_t0;
    std.debug.print("[perf] didSave+ping round-trip: {}ms\n", .{ping_ms});

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res2 = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res2.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: hover has no bold title, completion uses arg snippets, inlay hints show param names" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
        "fun add(num a, num b) num {\n" ++
        "  ret a + b;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  num r = add(1, 2);\n" ++
        "  Point p;\n" ++
        "  p.x = r;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-features.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // --- Hover on `add` (its definition) must NOT contain a bold "**add**" title.
    const add_def = try findPosition(doc_text, "fun add", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, add_def.line, add_def.col + 4 },
    );
    defer allocator.free(hover_params);
    // 45s (not the usual 5s): this is the first request the test issues
    // after opening the doc, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const hov_id = try lsp.request("textDocument/hover", hover_params);
    var hov_res = try lsp.waitResponse(hov_id, 45000);
    defer hov_res.deinit();
    const hov_result = try jsonResultFromResponseObj(hov_res.parsed.value.object);
    if (hov_result == .object) {
        if (hov_result.object.get("contents")) |c| {
            if (c == .object) {
                if (c.object.get("value")) |v| {
                    if (v == .string) {
                        // Go-style: no markdown bold title anywhere in the hover.
                        try std.testing.expect(std.mem.indexOf(u8, v.string, "**") == null);
                        // The signature should still be present.
                        try std.testing.expect(std.mem.indexOf(u8, v.string, "add(num a, num b)") != null);
                    }
                }
            }
        }
    }

    // --- Completion at the call site: the `add` item must carry a snippet.
    const comp_pos = try findPosition(doc_text, "num r = ad", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_pos.line, comp_pos.col + @as(i64, @intCast("num r = ad".len)) },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 5000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    if (comp_result == .object) {
        if (comp_result.object.get("items")) |items_v| {
            if (items_v == .array) {
                for (items_v.array.items) |it| {
                    if (it != .object) continue;
                    const lbl = it.object.get("label") orelse continue;
                    if (lbl != .string or !std.mem.eql(u8, lbl.string, "add")) continue;
                    // Snippet format (2) with a placeholder insert text.
                    if (it.object.get("insertTextFormat")) |fmt_v| {
                        try std.testing.expect(fmt_v == .integer and fmt_v.integer == 2);
                    }
                    if (it.object.get("insertText")) |ins_v| {
                        try std.testing.expect(ins_v == .string and std.mem.indexOf(u8, ins_v.string, "${1:") != null);
                    }
                }
            }
        }
    }

    // --- Inlay hints over the whole file: expect `a:` and `b:` at the add(1,2) call.
    const inlay_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":100,\"character\":0}}}}}}",
        .{doc_uri},
    );
    defer allocator.free(inlay_params);
    const inlay_id = try lsp.request("textDocument/inlayHint", inlay_params);
    var inlay_res = try lsp.waitResponse(inlay_id, 5000);
    defer inlay_res.deinit();
    const inlay_result = try jsonResultFromResponseObj(inlay_res.parsed.value.object);
    var saw_a = false;
    var saw_b = false;
    if (inlay_result == .array) {
        for (inlay_result.array.items) |h| {
            if (h != .object) continue;
            const lbl = h.object.get("label") orelse continue;
            if (lbl != .string) continue;
            if (std.mem.eql(u8, lbl.string, "a:")) saw_a = true;
            if (std.mem.eql(u8, lbl.string, "b:")) saw_b = true;
        }
    }
    try std.testing.expect(saw_a and saw_b);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: nil and fork keywords have hover docs and completion entries" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Prefix lines `ni;` and `fo;` (like the async/await test's `a;`/`aw;`) drive
    // prefix-filtered keyword completion; `num* p = nil;` and the real `fork` give
    // hover targets.
    const doc_text =
        "imp std.channel;\n\n" ++
        "async fun worker(Channel<num>* out, num v) {\n" ++
        "  out <- v;\n" ++
        "}\n\n" ++
        "fun main() num {\n" ++
        "  num* p = nil;\n" ++
        "  ni;\n" ++
        "  fo;\n" ++
        "  Channel<num> ch = channel_new_cap(0, 4);\n" ++
        "  fork worker(&ch, 5);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-nil-fork.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on `nil` in `num* p = nil;` -> mentions the null literal / NULL.
    const nil_pos = try findPosition(doc_text, "  num* p = nil;\n", 0);
    const nil_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, nil_pos.line, nil_pos.col + @as(i64, @intCast("  num* p = ".len)) },
    );
    defer allocator.free(nil_hover_params);
    const nil_hover_id = try lsp.request("textDocument/hover", nil_hover_params);
    var nil_hover_res = try lsp.waitResponse(nil_hover_id, 15000);
    defer nil_hover_res.deinit();
    const nil_hover_val = try jsonResultFromResponseObj(nil_hover_res.parsed.value.object);
    try expectHoverContains(allocator, nil_hover_val, "null");

    // Hover on `fork` -> mentions virtual thread.
    const fork_pos = try findPosition(doc_text, "  fork worker(&ch, 5);\n", 0);
    const fork_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, fork_pos.line, fork_pos.col + @as(i64, @intCast("  fo".len)) },
    );
    defer allocator.free(fork_hover_params);
    const fork_hover_id = try lsp.request("textDocument/hover", fork_hover_params);
    var fork_hover_res = try lsp.waitResponse(fork_hover_id, 15000);
    defer fork_hover_res.deinit();
    const fork_hover_val = try jsonResultFromResponseObj(fork_hover_res.parsed.value.object);
    try expectHoverContains(allocator, fork_hover_val, "virtual thread");

    // Note: `nil` and `fork` are also added to the keyword-completion list (the same
    // array validated by the async/await completion test), so completion membership
    // is covered there; this test focuses on the hover docs unique to nil/fork.

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: panic keyword has a hover doc" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun foo(num x) num {\n" ++
        "  if x < 0 {\n" ++
        "    ret panic(\"x must be non-negative\");\n" ++
        "  }\n" ++
        "  ret x * 2;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-panic.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on `panic` -> mentions unifying with the expected type.
    const panic_pos = try findPosition(doc_text, "    ret panic(\"x must be non-negative\");\n", 0);
    const panic_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, panic_pos.line, panic_pos.col + @as(i64, @intCast("    ret pa".len)) },
    );
    defer allocator.free(panic_hover_params);
    const panic_hover_id = try lsp.request("textDocument/hover", panic_hover_params);
    var panic_hover_res = try lsp.waitResponse(panic_hover_id, 15000);
    defer panic_hover_res.deinit();
    const panic_hover_val = try jsonResultFromResponseObj(panic_hover_res.parsed.value.object);
    try expectHoverContains(allocator, panic_hover_val, "Unifies");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: fork used as an ordinary function (not the statement) does not get keyword hover" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // `fork` is a CONTEXTUAL keyword: reserved only in statement position
    // (`fork some_call();`), so it can also be declared/called as an ordinary
    // function (e.g. a raw libc `fork()` binding). Hovering over ITS OWN
    // declaration or a call to it must show ordinary identifier behavior
    // (i.e. NOT the "virtual thread" keyword doc from the test above) --
    // `buildSemanticTokens` reads the exact same underlying classification
    // this hover check does, so this also guards the syntax-highlighting
    // color (previously misreported as keyword-blue for a `fork()` binding).
    const doc_text =
        "pub fun fork() num;\n\n" ++
        "fun main() num {\n" ++
        "  let pid = fork();\n" ++
        "  ret pid;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fork-as-fn.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on the DECLARATION's `fork`.
    const decl_pos = try findPosition(doc_text, "pub fun fork() num;\n", 0);
    const decl_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, decl_pos.line, decl_pos.col + @as(i64, @intCast("pub fun fo".len)) },
    );
    defer allocator.free(decl_hover_params);
    const decl_hover_id = try lsp.request("textDocument/hover", decl_hover_params);
    var decl_hover_res = try lsp.waitResponse(decl_hover_id, 15000);
    defer decl_hover_res.deinit();
    const decl_hover_val = try jsonResultFromResponseObj(decl_hover_res.parsed.value.object);
    try expectHoverNotContains(allocator, decl_hover_val, "virtual thread");

    // Hover on the CALL SITE's `fork`.
    const call_pos = try findPosition(doc_text, "  let pid = fork();\n", 0);
    const call_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + @as(i64, @intCast("  let pid = fo".len)) },
    );
    defer allocator.free(call_hover_params);
    const call_hover_id = try lsp.request("textDocument/hover", call_hover_params);
    var call_hover_res = try lsp.waitResponse(call_hover_id, 15000);
    defer call_hover_res.deinit();
    const call_hover_val = try jsonResultFromResponseObj(call_hover_res.parsed.value.object);
    try expectHoverNotContains(allocator, call_hover_val, "virtual thread");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: inlay hint shows the called function's own param name, not another fn's" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Mirrors the reported screenshot: a sibling fn `other(num j)` and the called
    // fn `score(num a)`, with `score(...)` calls NESTED inside a wrapped multi-line
    // `printf(...)`. The hint for a `score(a)` arg must be `a:` (score's own param)
    // — and since the arg is the identifier `a`, it is suppressed as redundant —
    // and must NEVER be `j:` (the sibling's param). This guards both signature
    // resolution and the nested-call walk inside a wrapped outer call.
    const doc_text =
        "fun other(num j) num {\n" ++
        "  ret j;\n" ++
        "}\n\n" ++
        "fun score(num a) num {\n" ++
        "  ret a;\n" ++
        "}\n\n" ++
        "fun main() num {\n" ++
        "  num a = 1;\n" ++
        "  num q = 3;\n" ++
        "  num s = score(q);\n" ++
        "  printf(\n" ++
        "    \"%lld %lld\\n\",\n" ++
        "    score(a),\n" ++
        "    score(a)\n" ++
        "  );\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-inlay-correct-param.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const inlay_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":100,\"character\":0}}}}}}",
        .{doc_uri},
    );
    defer allocator.free(inlay_params);
    // 45s (not the usual 5s): this is the first request the test issues
    // after opening the doc, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const inlay_id = try lsp.request("textDocument/inlayHint", inlay_params);
    var inlay_res = try lsp.waitResponse(inlay_id, 45000);
    defer inlay_res.deinit();
    const inlay_result = try jsonResultFromResponseObj(inlay_res.parsed.value.object);
    var saw_a = false;
    var saw_j = false;
    if (inlay_result == .array) {
        for (inlay_result.array.items) |h| {
            if (h != .object) continue;
            const lbl = h.object.get("label") orelse continue;
            if (lbl != .string) continue;
            if (std.mem.eql(u8, lbl.string, "a:")) saw_a = true;
            if (std.mem.eql(u8, lbl.string, "j:")) saw_j = true;
        }
    }
    try std.testing.expect(saw_a); // score's own param
    try std.testing.expect(!saw_j); // never the other function's param

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: a parameter default does not corrupt inlay hints or completion snippets" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // `times = 42` is a parameter DEFAULT. FLS must not mistake the default value `42`
    // for the parameter name: the inlay hint at the call must be `name:` (the first
    // param), never `42:`, and the completion snippet must use `${1:name}`, not `${1:42}`.
    const doc_text =
        "fun greet(str name, num times = 42) num {\n" ++
        "  _ = name;\n" ++
        "  ret times;\n" ++
        "}\n\n" ++
        "fun main() num {\n" ++
        "  ret greet(\"a\");\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-default-param.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Inlay hint at the `greet("a")` call -> first-param hint is `name:`, never `42:`.
    const inlay_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":100,\"character\":0}}}}}}",
        .{doc_uri},
    );
    defer allocator.free(inlay_params);
    // 45s (not the usual 5s): this is the first request the test issues
    // after opening the doc, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const inlay_id = try lsp.request("textDocument/inlayHint", inlay_params);
    var inlay_res = try lsp.waitResponse(inlay_id, 45000);
    defer inlay_res.deinit();
    const inlay_result = try jsonResultFromResponseObj(inlay_res.parsed.value.object);
    if (inlay_result == .array) {
        for (inlay_result.array.items) |h| {
            if (h != .object) continue;
            const lbl = h.object.get("label") orelse continue;
            if (lbl != .string) continue;
            // The default value must never leak as a hint label.
            try std.testing.expect(std.mem.indexOf(u8, lbl.string, "42") == null);
        }
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: hover on a function with a defaulted parameter shows the default value" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // `num times = 3` is a parameter DEFAULT. Hovering the function name, at its
    // own declaration and again at a call site, must render `num times = 3` in
    // the signature -- the way the original Fun source declares it -- not just
    // `num times` with the default silently dropped.
    const doc_text =
        "fun greet(str name, num times = 3) num {\n" ++
        "  _ = name;\n" ++
        "  ret times;\n" ++
        "}\n\n" ++
        "fun main() num {\n" ++
        "  ret greet(\"a\");\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-hover-default-param.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on the `greet` declaration name.
    const decl_pos = try findPosition(doc_text, "fun greet(str name, num times = 3) num {\n", 0);
    const decl_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, decl_pos.line, decl_pos.col + @as(i64, @intCast("fun ".len)) },
    );
    defer allocator.free(decl_hover_params);
    // 45s (not the usual 15s): unlike other hover tests in this file, this
    // hover is the FIRST request after opening the doc, so it alone pays the
    // full first-request workspace-indexing cost against the whole repo
    // (which has grown substantially during the self-hosting port) rather
    // than warming up via an earlier completion/definition call.
    const decl_hover_id = try lsp.request("textDocument/hover", decl_hover_params);
    var decl_hover_res = try lsp.waitResponse(decl_hover_id, 45000);
    defer decl_hover_res.deinit();
    const decl_hover_val = try jsonResultFromResponseObj(decl_hover_res.parsed.value.object);
    try expectHoverContains(allocator, decl_hover_val, "num times = 3");

    // Hover on the `greet` call site.
    const call_pos = try findPosition(doc_text, "  ret greet(\"a\");\n", 0);
    const call_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + @as(i64, @intCast("  ret ".len)) },
    );
    defer allocator.free(call_hover_params);
    const call_hover_id = try lsp.request("textDocument/hover", call_hover_params);
    var call_hover_res = try lsp.waitResponse(call_hover_id, 15000);
    defer call_hover_res.deinit();
    const call_hover_val = try jsonResultFromResponseObj(call_hover_res.parsed.value.object);
    try expectHoverContains(allocator, call_hover_val, "num times = 3");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: data-enum fit arm binding has typed hover and member completion" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // A data-carrying enum whose `Point` variant carries a `Vec2` compound. In the
    // arm `Json.Point(p) -> { ... }`, the binding `p` must be a typed local: hover
    // shows `Vec2`, and member completion `p.` offers Vec2's fields `x`/`y`.
    const doc_text =
        "compound Vec2 {\n" ++
        "  num x;\n" ++
        "  num y;\n" ++
        "}\n\n" ++
        "compound Box<T> {\n" ++
        "  T val;\n" ++
        "}\n\n" ++
        "enum Json {\n" ++
        "  Number(num),\n" ++
        "  Point(Vec2),\n" ++
        "  Boxed(Box<num>),\n" ++
        "  Null,\n" ++
        "}\n\n" ++
        "fun score(Json j) num {\n" ++
        "  fit j {\n" ++
        "    Json.Point(p) -> {\n" ++
        "      num t = p.x;\n" ++
        "      ret t;\n" ++
        "    }\n" ++
        "    Json.Boxed(b) -> {\n" ++
        "      num u = b.val;\n" ++
        "      ret u;\n" ++
        "    }\n" ++
        "    _ -> { ret 0; }\n" ++
        "  }\n" ++
        "  ret -1;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fit-binding.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on the binding `p` in `num t = p.x;` (the receiver) -> type Vec2.
    const p_pos = try findPosition(doc_text, "      num t = p.x;\n", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, p_pos.line, p_pos.col + @as(i64, @intCast("      num t = ".len)) },
    );
    defer allocator.free(hover_params);
    const hover_id = try lsp.request("textDocument/hover", hover_params);
    var hover_res = try lsp.waitResponse(hover_id, 15000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "Vec2");

    // Member completion at `p.` (just after the dot) -> Vec2 fields x and y.
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, p_pos.line, p_pos.col + @as(i64, @intCast("      num t = p.".len)) },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result, "x");
    try expectCompletionHasLabel(allocator, comp_result, "y");

    // The GENERIC payload binding `b` keeps `Box<num>`, so hovering its field
    // `b.val` resolves to the SUBSTITUTED `num` (not the bare type parameter `T`).
    const bval_pos = try findPosition(doc_text, "      num u = b.val;\n", 0);
    const bval_hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, bval_pos.line, bval_pos.col + @as(i64, @intCast("      num u = b.".len)) },
    );
    defer allocator.free(bval_hover_params);
    const bval_hover_id = try lsp.request("textDocument/hover", bval_hover_params);
    var bval_hover_res = try lsp.waitResponse(bval_hover_id, 15000);
    defer bval_hover_res.deinit();
    const bval_hover_val = try jsonResultFromResponseObj(bval_hover_res.parsed.value.object);
    try expectHoverContains(allocator, bval_hover_val, "num");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fun -ast flushes and prints the parsed AST" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    // Regression: `-ast` used a buffered stdout writer that was never flushed,
    // so it printed nothing. Spawn the real binary and assert AST text appears.
    const src =
        "fun add(num a, num b) num {\n" ++
        "  ret a + b;\n" ++
        "}\n";
    const ast_fn = "fls-e2e-ast.fn";
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, ast_fn, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, src);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ast_fn) catch {};

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ setup.fun_abs, "-in", ast_fn, "-ast", "-no-exec" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Node Type: Function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Name: add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Return Type: num") != null);
}

test "fls e2e: hover on a generic method specializes type params to the receiver" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Self-contained generic so the test does not depend on stdlib internals.
    const doc_text =
        "compound Box<T> {\n" ++
        "  T value;\n" ++
        "}\n\n" ++
        "impl Box<T> {\n" ++
        "  pub get_or(T fallback) T {\n" ++
        "    ret self.value;\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Box<num> b;\n" ++
        "  num r = b.get_or(0);\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-generic-hover.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on `get_or` in `b.get_or(0)`.
    const call_pos = try findPosition(doc_text, "b.get_or", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + 2 }, // +2 to land on `get_or`
    );
    defer allocator.free(hover_params);
    // 45s (not the usual 5s): this is the first request the test issues
    // after opening the doc, so it alone pays the full first-request
    // workspace-indexing cost (which has grown substantially during the
    // self-hosting port) rather than warming up via an earlier request.
    const hov_id = try lsp.request("textDocument/hover", hover_params);
    var hov_res = try lsp.waitResponse(hov_id, 45000);
    defer hov_res.deinit();

    const hov_result = try jsonResultFromResponseObj(hov_res.parsed.value.object);
    if (hov_result == .object) {
        if (hov_result.object.get("contents")) |c| {
            if (c == .object) {
                if (c.object.get("value")) |v| {
                    if (v == .string) {
                        // The receiver is Box<num>, so T must be shown as num — not T.
                        try std.testing.expect(std.mem.indexOf(u8, v.string, "get_or(num fallback) num") != null);
                    }
                }
            }
        }
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: code action fills in missing fit arms for a non-exhaustive enum match" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n" ++
        "enum Color { Red, Green, Blue }\n" ++
        "fun main() num {\n" ++
        "  Color c = Color.Red;\n" ++
        "  fit c {\n" ++
        "    Color.Red -> { ret 1; }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-codeaction-fit-arms.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const fit_pos = try findPosition(doc_text, "fit c {", 0);
    const fit_end = fit_pos.col + @as(i64, @intCast("fit".len));

    const code_action_params = try std.fmt.allocPrint(
        allocator,
        "{{" ++
            "\"textDocument\":{{\"uri\":\"{s}\"}}," ++
            "\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}," ++
            "\"context\":{{\"diagnostics\":[" ++
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":2,\"code\":\"fit_non_exhaustive\"," ++
            "\"message\":\"fit statement is not exhausted for enum 'Color' condition (missing: Color.Green, Color.Blue; add catch-all '_' branch to silence)\"}}" ++
            "]}}" ++
            "}}",
        .{
            doc_uri,
            fit_pos.line,
            fit_pos.col,
            fit_pos.line,
            fit_end,
            fit_pos.line,
            fit_pos.col,
            fit_pos.line,
            fit_end,
        },
    );
    defer allocator.free(code_action_params);

    const ca_id = try lsp.request("textDocument/codeAction", code_action_params);
    var ca_res = try lsp.waitResponse(ca_id, 15000);
    defer ca_res.deinit();
    const ca_val = try jsonResultFromResponseObj(ca_res.parsed.value.object);

    try expectCodeActionHasTitleWithNewText(
        allocator,
        ca_val,
        "Fill in missing fit arms",
        "    Color.Green -> {}\n    Color.Blue -> {}\n",
    );

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: code action fills in missing fit arms for a generic data-carrying enum" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // `Choice<T>`: `One` carries a single payload, `Two` carries two — checks
    // that the fix reads each missing variant's REAL payload arity (not just
    // "0 or 1"), and that a GENERIC enum's bare declared name (the message
    // says "enum 'Choice'", not "Choice<num>") still resolves correctly.
    const doc_text =
        "imp std.c.io;\n" ++
        "enum Choice<T> {\n" ++
        "  One(T),\n" ++
        "  Two(T, T),\n" ++
        "  None\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Choice<num> c = Choice.None;\n" ++
        "  fit c {\n" ++
        "    Choice.None -> { ret 0; }\n" ++
        "  }\n" ++
        "  ret -1;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-codeaction-fit-arms-generic.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const fit_pos = try findPosition(doc_text, "fit c {", 0);
    const fit_end = fit_pos.col + @as(i64, @intCast("fit".len));

    const code_action_params = try std.fmt.allocPrint(
        allocator,
        "{{" ++
            "\"textDocument\":{{\"uri\":\"{s}\"}}," ++
            "\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}," ++
            "\"context\":{{\"diagnostics\":[" ++
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":2,\"code\":\"fit_non_exhaustive\"," ++
            "\"message\":\"fit statement is not exhausted for enum 'Choice' condition (missing: Choice.One, Choice.Two; add catch-all '_' branch to silence)\"}}" ++
            "]}}" ++
            "}}",
        .{
            doc_uri,
            fit_pos.line,
            fit_pos.col,
            fit_pos.line,
            fit_end,
            fit_pos.line,
            fit_pos.col,
            fit_pos.line,
            fit_end,
        },
    );
    defer allocator.free(code_action_params);

    const ca_id = try lsp.request("textDocument/codeAction", code_action_params);
    var ca_res = try lsp.waitResponse(ca_id, 15000);
    defer ca_res.deinit();
    const ca_val = try jsonResultFromResponseObj(ca_res.parsed.value.object);

    try expectCodeActionHasTitleWithNewText(
        allocator,
        ca_val,
        "Fill in missing fit arms",
        "    Choice.One(v0) -> {}\n    Choice.Two(v0, v1) -> {}\n",
    );

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: code action implements missing quirk methods on an impl block" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.quirks;\n" ++
        "quirk Greet {\n" ++
        "  hello() str;\n" ++
        "  bye() str;\n" ++
        "}\n" ++
        "compound P { num x; }\n" ++
        "impl P as Greet {\n" ++
        "  pub hello() str { ret \"hi\"; }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-codeaction-quirk-methods.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const impl_pos = try findPosition(doc_text, "impl P as Greet {", 0);
    const impl_end = impl_pos.col + @as(i64, @intCast("impl".len));

    const code_action_params = try std.fmt.allocPrint(
        allocator,
        "{{" ++
            "\"textDocument\":{{\"uri\":\"{s}\"}}," ++
            "\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}," ++
            "\"context\":{{\"diagnostics\":[" ++
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1," ++
            "\"message\":\"impl 'P' for quirk 'Greet' is missing 1 method(s):\\n- bye() str\\n\"}}" ++
            "]}}" ++
            "}}",
        .{
            doc_uri,
            impl_pos.line,
            impl_pos.col,
            impl_pos.line,
            impl_end,
            impl_pos.line,
            impl_pos.col,
            impl_pos.line,
            impl_end,
        },
    );
    defer allocator.free(code_action_params);

    const ca_id = try lsp.request("textDocument/codeAction", code_action_params);
    var ca_res = try lsp.waitResponse(ca_id, 15000);
    defer ca_res.deinit();
    const ca_val = try jsonResultFromResponseObj(ca_res.parsed.value.object);

    try expectCodeActionHasTitleWithNewText(
        allocator,
        ca_val,
        "Implement missing quirk methods",
        "  pub bye() str {\n    // TODO: implement\n  }\n",
    );

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: missing quirk method diagnostic substitutes the concrete generic arg, not the bare type param" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    // `impl Config as From<JsonValue>` with the `from` method omitted: the
    // real compiler diagnostic (which both the raw CLI error output and the
    // fls "Implement missing quirk methods" code action's stub text are
    // built from) must report the SUBSTITUTED signature `from(JsonValue
    // value)`, not the generic template's bare `from(T value)` — otherwise
    // any fix built from it (manual or via the code action) inserts a stub
    // that doesn't typecheck.
    const doc_text =
        "imp std.json;\n" ++
        "imp std.quirks;\n" ++
        "compound Config {\n" ++
        "  num port;\n" ++
        "}\n" ++
        "impl Config as From<JsonValue> {\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  ret 0;\n" ++
        "}\n";

    const tmp_path = "fls-e2e-quirk-generic-diag.fn";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, tmp_path, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, doc_text);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ setup.fun_abs, "-in", tmp_path, "-no-exec" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "from(JsonValue value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "from(T value)") == null);
}

fn collectCompletionLabels(allocator: Allocator, result_val: std.json.Value) !ArrayList([]const u8) {
    var labels = ArrayList([]const u8).init(allocator);
    const items_val_opt: ?std.json.Value = switch (result_val) {
        .object => |o| o.get("items"),
        .array => result_val,
        else => null,
    };
    if (items_val_opt) |items_val| {
        if (items_val == .array) {
            for (items_val.array.items) |it| {
                if (it != .object) continue;
                const lbl = it.object.get("label") orelse continue;
                if (lbl != .string) continue;
                try labels.append(lbl.string);
            }
        }
    }
    return labels;
}

fn labelsContain(labels: []const []const u8, name: []const u8) bool {
    for (labels) |l| {
        if (std.mem.eql(u8, l, name)) return true;
    }
    return false;
}

test "fls e2e: completion after a call-argument '(' skips statement/type keyword noise" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n" ++
        "compound Box { num value; }\n" ++
        "impl Box {\n" ++
        "  pub add(num other) num {\n" ++
        "    printf(\n" ++
        "    ret self.value + other;\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Box b;\n" ++
        "  b.value = 1;\n" ++
        "  ret b.add(2);\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-paren-completion.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Case 1: right after `printf(` — a CALL argument position. Statement
    // keywords (`fun`, `if`, `for`, ...) and bare type keywords (`num`, `str`,
    // ...) can never start a value expression there and are noise; locals
    // (`self`, `other`) and literal-value keywords (`true`/`false`/`nil`)
    // remain relevant.
    {
        const pos = try findPosition(doc_text, "printf(\n", 0);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + @as(i64, @intCast("printf(".len)) },
        );
        defer allocator.free(params);
        const cid = try lsp.request("textDocument/completion", params);
        var res = try lsp.waitResponse(cid, 10000);
        defer res.deinit();
        const result = try jsonResultFromResponseObj(res.parsed.value.object);
        var labels = try collectCompletionLabels(allocator, result);
        defer labels.deinit();

        try std.testing.expect(!labelsContain(labels.items, "fun"));
        try std.testing.expect(!labelsContain(labels.items, "pub"));
        try std.testing.expect(!labelsContain(labels.items, "if"));
        try std.testing.expect(!labelsContain(labels.items, "num"));
        try std.testing.expect(!labelsContain(labels.items, "str"));
        try std.testing.expect(labelsContain(labels.items, "true"));
        try std.testing.expect(labelsContain(labels.items, "self"));
        try std.testing.expect(labelsContain(labels.items, "other"));
    }

    // Case 2: right after `pub add(` — a PARAMETER LIST declaration, where
    // type keywords are exactly what's needed and must NOT be suppressed.
    {
        const pos = try findPosition(doc_text, "pub add(", 0);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + @as(i64, @intCast("pub add(".len)) },
        );
        defer allocator.free(params);
        const cid = try lsp.request("textDocument/completion", params);
        var res = try lsp.waitResponse(cid, 10000);
        defer res.deinit();
        const result = try jsonResultFromResponseObj(res.parsed.value.object);
        var labels = try collectCompletionLabels(allocator, result);
        defer labels.deinit();

        try std.testing.expect(labelsContain(labels.items, "num"));
        try std.testing.expect(labelsContain(labels.items, "str"));
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: dot-shorthand completion at a call-arg boundary narrows to the expected param's own enum" {
    // Regression test for a reported completion bug: with more than one enum in
    // scope, `.` completion for a specific call-argument position was dumping
    // EVERY enum's variants (plus, in other contexts, unrelated functions)
    // instead of narrowing to the ONE enum expected at that argument position.
    //
    // Root cause: the cursor for a bare `.` sitting immediately before the
    // call's closing `)` (e.g. `paint(.Red, .)`) lands exactly on the shared
    // boundary between the `.` token and the `)` token. Token-range lookups
    // are start-inclusive/end-exclusive, so they resolved that boundary to the
    // `)` token, not the `.` just typed. `guessEnumTypeForDotShorthand` then
    // saw a `)` where it expected a dot-shorthand anchor, bailed out early
    // (returning null), and completion fell back to its "offer every enum in
    // scope" fallback path — silently discarding the call's active-parameter
    // type narrowing that would have selected only `Status`.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "enum Color {\n" ++
        "  Red,\n" ++
        "  Green,\n" ++
        "  Blue,\n" ++
        "}\n\n" ++
        "enum Status {\n" ++
        "  Ok,\n" ++
        "  Err,\n" ++
        "}\n\n" ++
        "fun helper_unrelated() {\n" ++
        "  ret;\n" ++
        "}\n\n" ++
        "fun paint(Color c, Status s) {\n" ++
        "  ret;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  paint(.Red, .);\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-enum-call-arg-narrowing.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Second-arg completion: `paint(.Red, .)` expects a `Status`. It must
    // offer ONLY `Ok`/`Err` -- never `Status`'s sibling enum `Color`'s
    // variants, and never unrelated free functions.
    const pos = try findPosition(doc_text, "paint(.Red, .)", 0);
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + @as(i64, @intCast("paint(.Red, .".len)) },
    );
    defer allocator.free(params);
    // 45s (not the usual 15s): this completion is the FIRST request after
    // opening the doc, so it alone pays the full first-request workspace-
    // indexing cost against the whole repo (which has grown substantially
    // during the self-hosting port) rather than warming up via an earlier
    // request, as most other tests in this file do.
    const cid = try lsp.request("textDocument/completion", params);
    var res = try lsp.waitResponse(cid, 45000);
    defer res.deinit();
    const result = try jsonResultFromResponseObj(res.parsed.value.object);

    try expectCompletionHasLabel(allocator, result, "Ok");
    try expectCompletionHasLabel(allocator, result, "Err");
    try expectCompletionMissingLabel(allocator, result, "Red");
    try expectCompletionMissingLabel(allocator, result, "Green");
    try expectCompletionMissingLabel(allocator, result, "Blue");
    try expectCompletionMissingLabel(allocator, result, "helper_unrelated");
    try expectCompletionMissingLabel(allocator, result, "paint");
    try expectCompletionMissingLabel(allocator, result, "main");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: a plain function call is not mistaken for a variant of an earlier enum with no trailing comma" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Regression (real repro from stdlib/std/error.fn): `ErrorKind`'s last
    // variant has no trailing comma before its closing `}` -- the token-based
    // enum-variant scanner's bare-variant branch used to skip past that `}`
    // without ever accounting for it in its own brace-depth tracking, so it
    // kept scanning past the enum's own body and misread the next
    // `identifier(...)` shape anywhere later in the file (here,
    // `error_new_kind`, an ordinary function) as one more data-carrying
    // `ErrorKind` variant. Hovering `error_new_kind` showed
    // `ErrorKind.error_new_kind(...)` instead of its real function signature.
    const err_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "stdlib", "std", "error.fn" });
    defer allocator.free(err_abs);
    const doc_text = blk: {
        var f = try std.Io.Dir.openFileAbsolute(std.testing.io, err_abs, .{});
        defer f.close(std.testing.io);
        break :blk try blk2: {
            var _rb: [65536]u8 = undefined;
            var _fr = f.reader(std.testing.io, &_rb);
            break :blk2 _fr.interface.allocRemaining(allocator, .limited(1024 * 1024));
        };
    };
    defer allocator.free(doc_text);
    const doc_uri = try pathToFileUriAlloc(allocator, err_abs);
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos = try findPosition(doc_text, "error_new_kind(.System", 0);
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + 3 },
    );
    defer allocator.free(params);
    const hid = try lsp.request("textDocument/hover", params);
    var res = try lsp.waitResponse(hid, 15000);
    defer res.deinit();
    const val = try jsonResultFromResponseObj(res.parsed.value.object);

    try expectHoverContains(allocator, val, "fun error_new_kind(ErrorKind kind, num code, str message) Error");
    try expectHoverNotContains(allocator, val, "ErrorKind.error_new_kind");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: a bare call is not shadowed by an unrelated compound field of the same name" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Regression (real repro from selfhost/lexer/lexer.fn): `Lexer` has a
    // field named `len`, and the body separately calls the free function
    // `len(src)`. A bare identifier (no preceding `.`) must never resolve to
    // a field/property/method/enum variant -- those all require a receiver
    // -- but `findBestDefinition` had no such exclusion, so whichever
    // same-named symbol happened to be indexed could win. Hovering the bare
    // `len(` call showed the FIELD's type (`num`) instead of the function's
    // signature, with no go-to-definition to the function.
    const doc_text =
        "imp std.c.io;\n" ++
        "imp std.string;\n\n" ++
        "compound Lexer {\n" ++
        "  str src;\n" ++
        "  num len;\n" ++
        "}\n\n" ++
        "fun lexer_new(str src) Lexer {\n" ++
        "  Lexer l;\n" ++
        "  l.src = src;\n" ++
        "  l.len = len(src);\n" ++
        "  ret l;\n" ++
        "}\n\n" ++
        "fun main() num {\n" ++
        "  Lexer l = lexer_new(\"hi\");\n" ++
        "  printf(\"%lld\\n\", l.len);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-len-field-vs-fn.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos = try findPosition(doc_text, "len(src)", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + 1 },
    );
    defer allocator.free(hover_params);
    const hid = try lsp.request("textDocument/hover", hover_params);
    var hover_res = try lsp.waitResponse(hid, 15000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "fun len(str s) num");

    const def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + 1 },
    );
    defer allocator.free(def_params);
    const did = try lsp.request("textDocument/definition", def_params);
    var def_res = try lsp.waitResponse(did, 15000);
    defer def_res.deinit();
    const def_val = try jsonResultFromResponseObj(def_res.parsed.value.object);
    // stdlib/std/string.fn:111: `pub fun len(str s) num {` (0-indexed line
    // 110, `len` starting at character 8 after `pub fun `).
    try expectDefinitionPointsTo(allocator, def_val, "string.fn", 110, 8);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: a local shadowing an earlier same-named local in an exited block hovers its own type" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Regression (real repro from selfhost/lexer/lexer.fn:365): fls only
    // tracks function-WIDE scope, not real block scope, so two same-named
    // locals in sibling blocks of the same function (the first exits via
    // `ret` before the second is ever reached) both look "in range" for the
    // whole function. The "prefer a more-resolved/non-builtin type" hover
    // heuristic (three separate copies: `findBestDefinition`, `pickBestLocal`,
    // and an inline pass in `handleHover`) had no guard against reaching
    // BACKWARD past the positionally-correct candidate, so the earlier `v`
    // (`Result<dec, Error>`) won over the later, actually-in-scope `v`
    // (`num`) purely because a Result type "looks more interesting" than a
    // builtin one.
    const doc_text =
        "imp std.c.io;\n" ++
        "imp std.result;\n\n" ++
        "fun try_parse_dec(str s) Result<dec, Error> {\n" ++
        "  ret .Ok(1.5);\n" ++
        "}\n\n" ++
        "fun try_parse_int(str s) Result<num, Error> {\n" ++
        "  ret .Ok(1);\n" ++
        "}\n\n" ++
        "fun check(str number_str, bin has_dot) num {\n" ++
        "  if has_dot {\n" ++
        "    let v = try_parse_dec(number_str);\n" ++
        "    if v.is_err() { ret -1; }\n" ++
        "    ret 0;\n" ++
        "  }\n" ++
        "  let iv = try_parse_int(number_str);\n" ++
        "  num v = iv.unwrap();\n" ++
        "  ret v;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-shadowed-local.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos = try findPosition(doc_text, "num v = iv.unwrap()", 0);
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + @as(i64, @intCast("num ".len)) },
    );
    defer allocator.free(params);
    const hid = try lsp.request("textDocument/hover", params);
    var res = try lsp.waitResponse(hid, 15000);
    defer res.deinit();
    const val = try jsonResultFromResponseObj(res.parsed.value.object);

    try expectHoverContains(allocator, val, "num v");
    try expectHoverNotContains(allocator, val, "Result");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: a function-type parameter's nested `fun(...)` does not clobber the enclosing method" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Regression (real repro from selfhost/lexer/lexer.fn's `_read_while`):
    // a function-TYPE parameter (`fun(chr) bin pred`) has its OWN nested
    // `fun` keyword. The top-level scanner treated EVERY `fun` token as the
    // start of a new top-level declaration and unconditionally reset all
    // pending-declaration state, so the nested `fun` inside `read_while`'s
    // own parameter list wiped out `read_while`'s in-progress params AND its
    // impl-method ownership before either was ever flushed at the method's
    // `{`. Two symptoms from the same root cause: `pred` hovered as a bare
    // `bin` (losing the callable shape entirely) instead of
    // `fun(chr) bin`, and the implicit `self` local silently never existed
    // inside `read_while`'s body at all.
    const doc_text =
        "imp std.c.io;\n\n" ++
        "compound Reader {\n" ++
        "  str src;\n" ++
        "  num pos;\n" ++
        "}\n\n" ++
        "impl Reader {\n" ++
        "  read_while(fun(chr) bin pred) str {\n" ++
        "    if pred('a') && self.pos < 1 { ret \"yes\"; }\n" ++
        "    ret \"no\";\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun is_digit_chr(chr c) bin { ret c >= '0' && c <= '9'; }\n\n" ++
        "fun main() num {\n" ++
        "  Reader r;\n" ++
        "  let s = r.read_while(is_digit_chr);\n" ++
        "  printf(\"%s\\n\", s);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fn-type-param.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pred_pos = try findPosition(doc_text, "pred('a')", 0);
    const pred_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pred_pos.line, pred_pos.col + 1 },
    );
    defer allocator.free(pred_params);
    const pred_hid = try lsp.request("textDocument/hover", pred_params);
    var pred_res = try lsp.waitResponse(pred_hid, 15000);
    defer pred_res.deinit();
    const pred_val = try jsonResultFromResponseObj(pred_res.parsed.value.object);
    try expectHoverContains(allocator, pred_val, "fun(chr) bin pred");

    // Regression: hovering `pred` at its OWN declaration site (inside the
    // parameter list, before the method's body `{`) is structurally outside
    // `container_fn_range` (which only spans the body), so the indexed-symbol
    // lookup used by the use-site check above never matches here -- this
    // falls all the way to `guessVariableType`'s best-effort token scanner,
    // which previously mistook the return-type token (`bin`) immediately
    // before `pred` for its WHOLE type, again losing the callable shape.
    const pred_decl_pos = try findPosition(doc_text, "pred) str {", 0);
    const pred_decl_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pred_decl_pos.line, pred_decl_pos.col + 1 },
    );
    defer allocator.free(pred_decl_params);
    const pred_decl_hid = try lsp.request("textDocument/hover", pred_decl_params);
    var pred_decl_res = try lsp.waitResponse(pred_decl_hid, 15000);
    defer pred_decl_res.deinit();
    const pred_decl_val = try jsonResultFromResponseObj(pred_decl_res.parsed.value.object);
    try expectHoverContains(allocator, pred_decl_val, "fun(chr) bin pred");

    const self_pos = try findPosition(doc_text, "self.pos", 0);
    const self_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, self_pos.line, self_pos.col + 1 },
    );
    defer allocator.free(self_params);
    const self_hid = try lsp.request("textDocument/hover", self_params);
    var self_res = try lsp.waitResponse(self_hid, 15000);
    defer self_res.deinit();
    const self_val = try jsonResultFromResponseObj(self_res.parsed.value.object);
    try expectHoverContains(allocator, self_val, "Reader*");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: hover on a function-type parameter that is NOT the first parameter" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Regression (real repro from `stdlib/std/testing.fn`'s `run_one`):
    // `guessVariableType`'s best-effort token scanner (the fallback used
    // when a function-type parameter is hovered at its OWN declaration
    // site, per the test above) walked forward from the start of the file
    // and paired the FIRST `Type name` match it found -- for `run_at`, that
    // was the bare return type (`bin`) immediately preceding it, not the
    // whole `fun(num) bin` signature. Being the SECOND parameter (after
    // `num i,`) wasn't itself the issue; any function-type parameter's
    // declaration-site hover hit this same fallback.
    const doc_text =
        "async fun run_one(num i, fun(num) bin run_at, num out) {\n" ++
        "  bin r = run_at(i);\n" ++
        "  _ = r;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-fn-type-param-not-first.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const decl_pos = try findPosition(doc_text, "run_at,", 0);
    const decl_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, decl_pos.line, decl_pos.col + 1 },
    );
    defer allocator.free(decl_params);
    const decl_hid = try lsp.request("textDocument/hover", decl_params);
    var decl_res = try lsp.waitResponse(decl_hid, 15000);
    defer decl_res.deinit();
    const decl_val = try jsonResultFromResponseObj(decl_res.parsed.value.object);
    try expectHoverContains(allocator, decl_val, "fun(num) bin run_at");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: a fit-arm destructuring binding resolves its type when the enum comes from an imported file" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache") catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/felfr") catch {};
    const defs_path = ".zig-cache/felfr/defs.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, defs_path) catch {};

    // Regression: `.Impl(i) ->` (a fit-arm destructuring binding) only
    // resolved its type when the enum's OWN declaration (`Impl(ImplNode)`)
    // was in the SAME file being scanned (`prescanEnumVariantPayloads`'s
    // per-file token scan). Declared here in a SEPARATE, imported file
    // instead -- the common shape for a large enum living in its own
    // module (e.g. this repo's own selfhost/ast/ast.fn + codegen.fn) --
    // `i`'s type previously fell through to unknown.
    //
    // NOTE: a further-reaching version of this fix also tried resolving
    // `i.methods`-shaped iterable field types cross-file (so a `for m :
    // i.methods` loop's OWN item `m` would resolve too), but that
    // regressed 4 OTHER tests -- it matched against the imported file's
    // raw, unsubstituted generic template symbols, preempting the separate
    // query-time engine that correctly substitutes a generic type param
    // with the caller's own concrete instantiation. Deliberately scoped
    // back to just the fit-binding itself; the field-access follow-on is a
    // known, deferred gap needing a more careful design.
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, defs_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
            "compound ImplNode {\n" ++
                "  str type_name;\n" ++
                "}\n\n" ++
                "enum NodeKind {\n" ++
                "  Impl(ImplNode),\n" ++
                "}\n",
        );
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp felfr.defs;\n\n" ++
        "fun handle(NodeKind k) num {\n" ++
        "  fit k {\n" ++
        "    .Impl(i) -> {\n" ++
        "      let x = i;\n" ++
        "    }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-cross-file-variant-binding.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover at the binding's OWN declaration site (`.Impl(i) ->`).
    const decl_pos = try findPosition(doc_text, ".Impl(i)", 0);
    const decl_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, decl_pos.line, decl_pos.col + 6 },
    );
    defer allocator.free(decl_params);
    const decl_hid = try lsp.request("textDocument/hover", decl_params);
    var decl_res = try lsp.waitResponse(decl_hid, 15000);
    defer decl_res.deinit();
    const decl_val = try jsonResultFromResponseObj(decl_res.parsed.value.object);
    try expectHoverContains(allocator, decl_val, "ImplNode");

    // Hover at a USE site inside the arm's body (`let x = i;`).
    const use_pos = try findPosition(doc_text, "let x = i;", 0);
    const use_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, use_pos.line, use_pos.col + 8 },
    );
    defer allocator.free(use_params);
    const use_hid = try lsp.request("textDocument/hover", use_params);
    var use_res = try lsp.waitResponse(use_hid, 15000);
    defer use_res.deinit();
    const use_val = try jsonResultFromResponseObj(use_res.parsed.value.object);
    try expectHoverContains(allocator, use_val, "ImplNode");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}
