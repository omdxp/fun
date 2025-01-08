const std = @import("std");
const io = std.io;
const mem = std.mem;
const heap = std.heap;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");
pub const global_allocator = heap.page_allocator;

pub fn main() !void {
    var p = try transpiler.TranspileProcess.init(
        global_allocator,
        "./test.fn",
        "./test.c",
        0,
    );
    defer p.ifile.close();
    defer p.ofile.close();
    defer p.tokens.deinit();

    try p.tokens.append(token.Token{
        .between_args = "",
        .between_brackets = "",
        .data = .{ .cval = 'c' },
        .type = .Symbol,
        .num = .{ .type = .Long },
        .whitespace = false,
    });
    for (p.tokens.items) |t| {
        std.debug.print("t is {}\n", .{t});
    }

    const buffer = try p.ifile.readToEndAlloc(global_allocator, 2064);
    defer global_allocator.free(buffer);

    try p.ofile.writeAll(buffer);
}
