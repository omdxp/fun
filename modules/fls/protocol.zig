const std = @import("std");
const types = @import("types.zig");

fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const Allocator = std.mem.Allocator;

const Range = types.Range;

pub fn stringifyId(allocator: Allocator, id_val: ?std.json.Value) ![]u8 {
    if (id_val == null) return allocator.dupe(u8, "null");
    var aw = std.Io.Writer.Allocating.init(allocator);
    try std.json.fmt(id_val.?, .{}).format(&aw.writer);
    return aw.toOwnedSlice();
}

pub fn jsonStringifyAlloc(allocator: Allocator, value: anytype) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    try std.json.fmt(value, .{}).format(&aw.writer);
    return aw.toOwnedSlice();
}

pub fn writeLspMessageRaw(file: std.Io.File, io: std.Io, json: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json.len});
    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, json);
}

pub fn readLspMessage(allocator: Allocator, r: *std.Io.Reader) ![]u8 {
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

pub fn writeJsonString(buf: *ArrayList(u8), s: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(buf.allocator);
    defer aw.deinit();
    try std.json.fmt(s, .{}).format(&aw.writer);
    try buf.appendSlice(aw.written());
}

pub fn writeRangeJson(buf: *ArrayList(u8), r: Range) !void {
    try buf.print(
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ r.start.line, r.start.character, r.end.line, r.end.character },
    );
}
