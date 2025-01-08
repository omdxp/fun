const std = @import("std");
const token = @import("./token.zig");

pub fn main() !void {
    const t = token.Token{
        .data = .{ .sval = "this is a str" },
        .type = token.TokenType.String,
    };
    std.debug.print("t is {s}!\n", .{t.data.sval});
}
