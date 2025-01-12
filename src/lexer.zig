const std = @import("std");
const mem = std.mem;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");

pub const LexProcess = struct {
    tokens: std.ArrayList(token.Token),
    transpile_proc: *transpiler.TranspileProcess,
    curr_exp_count: u8,
    parenthesis_buf: []const u8,
    arg_str_buf: []const u8,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, transpile_proc: *transpiler.TranspileProcess) Self {
        return Self{
            .tokens = std.ArrayList(token.Token).init(allocator),
            .transpile_proc = transpile_proc,
            .curr_exp_count = 0,
            .parenthesis_buf = "",
            .arg_str_buf = "",
        };
    }

    pub fn next_char(self: *Self) !u8 {
        self.transpile_proc.pos.col += 1;
        var buffer: [1]u8 = undefined;
        _ = try self.transpile_proc.ifile.read(buffer[0..]);
        const c = buffer[0];
        if (c == '\n') {
            self.transpile_proc.pos.line += 1;
            self.transpile_proc.pos.col = 1;
        }
        return c;
    }

    pub fn peek_char(self: *Self) !u8 {
        const pos = try self.transpile_proc.ifile.seekableStream().getPos();
        var buffer: [1]u8 = undefined;
        _ = try self.transpile_proc.ifile.read(buffer[0..]);
        try self.transpile_proc.ifile.seekTo(pos);
        return buffer[0];
    }

    pub fn push_char(self: *Self, c: u8) !void {
        var buffer: [1]u8 = [_]u8{c};
        _ = try self.transpile_proc.ifile.write(buffer[0..]);
    }

    pub fn deinit(self: Self) void {
        self.tokens.deinit();
    }
};
