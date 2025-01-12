const std = @import("std");
const mem = std.mem;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");

pub const LexProcess = struct {
    pos: token.Pos,
    tokens: std.ArrayList(token.Token),
    transpile_proc: *transpiler.TranspileProcess,
    curr_exp_count: u8,
    parenthesis_buf: []const u8,
    arg_str_buf: []const u8,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, ifilepath: []const u8, transpile_proc: *transpiler.TranspileProcess) Self {
        return Self{
            .pos = .{ .col = 0, .line = 0, .filename = ifilepath },
            .tokens = std.ArrayList(token.Token).init(allocator),
            .transpile_proc = transpile_proc,
            .curr_exp_count = 0,
            .parenthesis_buf = "",
            .arg_str_buf = "",
        };
    }

    pub fn next_char(self: *Self) u8 {
        return 0;
    }

    pub fn peak_char(self: *Self) u8 {
        return 0;
    }

    pub fn push_char(self: *Self) void {
        return 0;
    }

    pub fn deinit(self: Self) void {
        self.tokens.deinit();
    }
};
