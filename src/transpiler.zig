const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const token = @import("./token.zig");

pub const TranspileProcess = struct {
    flags: u8,
    pos: token.Pos,
    ifile: fs.File,
    ofile: fs.File,
    tokens: std.ArrayList(token.Token),

    const Self = @This();

    pub fn init(allocator: mem.Allocator, ifilepath: []const u8, ofilepath: []const u8, flags: u8) !Self {
        const ifile = try fs.cwd().openFile(ifilepath, .{ .mode = .read_only });
        const ofile = try fs.cwd().createFile(ofilepath, .{ .read = true });

        return Self{
            .flags = flags,
            .pos = .{ .col = 0, .line = 0, .filename = ifilepath },
            .ifile = ifile,
            .ofile = ofile,
            .tokens = std.ArrayList(token.Token).init(allocator),
        };
    }
};
