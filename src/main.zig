const std = @import("std");
const token = @import("./token.zig");

pub fn main() !void {
    const t = token.Token{
        .data = .{ .cval = 'c' },
        .type = token.TokenType.Symbol,
    };
    std.debug.print("t is {}!\n", .{t});
}
