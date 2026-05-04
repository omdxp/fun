const std = @import("std");
const globals = @import("globals.zig");
const types = @import("types.zig");
const uri_utils = @import("uri.zig");
const positions_mod = @import("positions.zig");

fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const Allocator = std.mem.Allocator;

const globalIo = globals.globalIo;

const Position = types.Position;
const Range = types.Range;
const Diagnostic = types.Diagnostic;
const DiagnosticWithUri = types.DiagnosticWithUri;

const byteIndexForPosition = positions_mod.byteIndexForPosition;
const pathToUri = uri_utils.pathToUri;
const uriToPath = uri_utils.uriToPath;

const _skip_lsp_tests_in_ci = blk: {
    if (@hasDecl(@import("std").process, "getEnvVar")) {
        if (@import("std").process.getEnvVar("CI", null)) |ci| {
            if (ci.len > 0) break :blk true;
        }
    }
    break :blk false;
};

pub fn runCaptureStderr(allocator: Allocator, argv: []const []const u8, stderr_out: *ArrayList(u8)) !u8 {
    const io = globalIo();
    const res = try std.process.run(allocator, io, .{
        .argv = argv,
        .stderr_limit = .limited(10 * 1024 * 1024),
        .stdout_limit = .limited(10 * 1024 * 1024),
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    // Fun diagnostics historically used stderr, but some paths print to stdout;
    // merge both so we never lose messages.
    try stderr_out.appendSlice(res.stderr);
    try stderr_out.appendSlice(res.stdout);

    return switch (res.term) {
        .exited => |code| @intCast(code),
        else => 1,
    };
}

pub const ParsedDiagnosticTag = struct {
    severity: i64,
    code: ?[]const u8 = null,
};

pub fn parseDiagnosticTag(line: []const u8) ?ParsedDiagnosticTag {
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

pub fn inferDiagnosticCodeFromMessage(message: []const u8) ?[]const u8 {
    if (isMissingAwaitDiagnosticMessage(message)) return "async_call_requires_await";
    if (isAwaitOutsideAsyncDiagnosticMessage(message)) return "await_outside_async_function";
    return null;
}

pub fn parseFunDiagnosticsByUri(allocator: Allocator, stderr_text: []const u8, current_uri: []const u8, tmp_name: []const u8) ![]DiagnosticWithUri {
    const current_path_opt = uriToPath(allocator, current_uri) catch null;
    defer if (current_path_opt) |p| allocator.free(p);
    const current_dir_opt = if (current_path_opt) |p| std.fs.path.dirname(p) else null;

    var diags = ArrayList(DiagnosticWithUri).init(allocator);
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
    var pending_message: ?ArrayList(u8) = null;
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
            var msg = ArrayList(u8).init(allocator);
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
                        const ap = std.Io.Dir.cwd().realPathFileAlloc(globalIo(), file_part, allocator) catch null;
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
                            const ap2 = std.Io.Dir.cwd().realPathFileAlloc(globalIo(), j, allocator) catch null;
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

pub fn parseLocationWithFile(loc: []const u8, file_part: *[]const u8, start_line: *i64, start_col: *i64, end_line: *i64, end_col: *i64) bool {
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

pub fn tryApplyRangedEdit(allocator: Allocator, text: []const u8, start_pos: Position, end_pos: Position, new_text: []const u8) !?[]u8 {
    const start_b = byteIndexForPosition(text, start_pos);
    const end_b = byteIndexForPosition(text, end_pos);
    if (start_b > end_b or end_b > text.len) return null;

    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(text[0..start_b]);
    try out.appendSlice(new_text);
    try out.appendSlice(text[end_b..]);
    return try out.toOwnedSlice();
}

pub fn isMissingAwaitDiagnosticCode(code_opt: ?[]const u8) bool {
    const code = code_opt orelse return false;
    return std.mem.eql(u8, code, "async_call_requires_await");
}

pub fn isAwaitOutsideAsyncDiagnosticCode(code_opt: ?[]const u8) bool {
    const code = code_opt orelse return false;
    return std.mem.eql(u8, code, "await_outside_async_function");
}

pub fn isMissingAwaitDiagnosticMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "must be awaited") != null and
        std.mem.indexOf(u8, message, "async function") != null;
}

pub fn isAwaitOutsideAsyncDiagnosticMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "await is only allowed inside async functions") != null;
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

test "fls: parseFunDiagnosticsByUri maps tmp file to current uri" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    {
        var f = try tmp.dir.createFile(std.testing.io, "src/main.fn", .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), "// file\n");
    }

    const current_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.fn", allocator);
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

    try tmp.dir.createDirPath(std.testing.io, "src");
    {
        var f = try tmp.dir.createFile(std.testing.io, "src/main.fn", .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), "// file\n");
    }

    const current_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.fn", allocator);
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

    try tmp.dir.createDirPath(std.testing.io, "src");
    {
        var f = try tmp.dir.createFile(std.testing.io, "src/main.fn", .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), "// file\n");
    }

    const current_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.fn", allocator);
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

    try tmp.dir.createDirPath(std.testing.io, "src");
    {
        var f = try tmp.dir.createFile(std.testing.io, "src/main.fn", .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), "// file\n");
    }
    {
        var f2 = try tmp.dir.createFile(std.testing.io, "src/other.fn", .{ .read = true, .truncate = true });
        defer f2.close(globalIo());
        try f2.writeStreamingAll(globalIo(), "// other\n");
    }

    const current_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.fn", allocator);
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
