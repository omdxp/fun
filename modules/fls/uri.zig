const std = @import("std");
const globals = @import("globals.zig");

fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const Allocator = std.mem.Allocator;

const globalIo = globals.globalIo;

pub fn findSiblingOrPathExe(allocator: Allocator, io: std.Io, base_name: []const u8) ![]u8 {
    // 1) If `FLS_FUN_PATH` is set, use that.
    if (std.c.getenv("FLS_FUN_PATH")) |z| {
        const p = std.mem.sliceTo(z, 0);
        if (p.len > 0) return allocator.dupe(u8, p);
    }

    // 2) Try sibling next to fls exe.
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch null;
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
            std.Io.Dir.cwd().access(globalIo(), full, .{}) catch {
                allocator.free(full);
                break :sibling_check;
            };
            return full;
        }
    }

    // 3) Fall back to PATH lookup.
    return try findOnPath(allocator, base_name);
}

pub fn findOnPath(allocator: Allocator, base_name: []const u8) ![]u8 {
    const path_env_ptr = std.c.getenv("PATH") orelse return error.FileNotFound;
    const path_env = std.mem.sliceTo(path_env_ptr, 0);

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

        std.Io.Dir.cwd().access(globalIo(), full, .{}) catch {
            allocator.free(full);
            continue;
        };
        return full;
    }

    return error.FileNotFound;
}

pub fn isUriUnreserved(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/' or ch == ':';
}

pub fn pathToUri(allocator: Allocator, path_raw: []const u8) ![]u8 {
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

    var out = ArrayList(u8).init(allocator);
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
            try out.print("%{X:0>2}", .{ch});
        }
    }

    return out.toOwnedSlice();
}

pub fn hexValue(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => 10 + (ch - 'a'),
        'A'...'F' => 10 + (ch - 'A'),
        else => null,
    };
}

pub fn uriToPath(allocator: Allocator, uri: []const u8) ![]u8 {
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

    var out = ArrayList(u8).init(allocator);
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
