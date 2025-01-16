const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const token = @import("./token.zig");

/// TranspileProcessFlags is an enumeration that defines flags for the transpile process.
///
/// Each flag is represented as a bit in an 8-bit unsigned integer.
pub const TranspileProcessFlags = enum(u8) {
    /// Flag to indicate execution process.
    TranspileProcessExec = 0b0000_0001,
    /// Flag to indicate output file process.
    TranspileProcessOutf = 0b0000_0010,
};

/// `TranspileProcess` represents the state and configuration of a transpilation process.
pub const TranspileProcess = struct {
    /// `flags` is a set of flags that control the behavior of the transpilation process.
    flags: TranspileProcessFlags,
    /// `pos` is the current position in the token stream.
    pos: token.Pos,
    /// `ifile` is the input file being read for transpilation.
    ifile: fs.File,
    /// `ofile` is the output file where the transpiled code will be written.
    ofile: fs.File,
    /// `tokens` is a list of tokens generated from the input file.
    tokens: std.ArrayList(token.Token),

    const Self = @This();

    /// Initializes a new instance of `TranspileProcess`.
    ///
    /// This function opens the input file in read-only mode and creates the output file
    /// with read permissions. It also initializes the token list with the provided allocator.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for the token list.
    /// - `ifilepath`: The file path of the input file.
    /// - `ofilepath`: The file path of the output file.
    /// - `flags`: The flags to set for the transpiler.
    ///
    /// Returns:
    /// - `Self`: A new instance of `TranspileProcess`.
    ///
    /// Errors:
    /// - Returns an error if opening the input file or creating the output file fails.
    pub fn init(allocator: mem.Allocator, ifilepath: []const u8, ofilepath: []const u8, flags: TranspileProcessFlags) !Self {
        const ifile = try fs.cwd().openFile(ifilepath, .{ .mode = .read_write });
        const ofile = try fs.cwd().createFile(ofilepath, .{ .read = true });

        return Self{
            .flags = flags,
            .pos = .{ .col = 1, .line = 1, .filename = ifilepath },
            .ifile = ifile,
            .ofile = ofile,
            .tokens = std.ArrayList(token.Token).init(allocator),
        };
    }

    /// Logs an error message with the current position in the token stream.
    ///
    /// This function logs an error message along with the line number, column number,
    /// and filename where the error occurred, then panics.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `msg`: The error message to log.
    pub fn error_message(self: Self, msg: []const u8) void {
        self.deinit();
        std.debug.panic("Error: {s} on line {d}, col {d} in file {s}", .{
            msg,
            self.pos.line,
            self.pos.col,
            self.pos.filename,
        });
    }

    /// Logs a warning message with the current position in the token stream.
    ///
    /// This function logs a warning message along with the line number, column number,
    /// and filename where the warning occurred.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `msg`: The warning message to log.
    pub fn warn_message(self: Self, msg: []const u8) void {
        std.debug.print("Warning: {s} on line {d}, col {d} in file {s}\n", .{
            msg,
            self.pos.line,
            self.pos.col,
            self.pos.filename,
        });
    }

    /// Deinitializes the transpiler by closing input and output files and deinitializing tokens.
    ///
    /// This function performs the following actions:
    /// - Closes the input file associated with the transpiler.
    /// - Closes the output file associated with the transpiler.
    /// - Deinitializes the tokens used by the transpiler.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler to deinitialize.
    ///
    /// Returns:
    /// - This function does not return any value.
    pub fn deinit(self: Self) void {
        self.ifile.close();
        self.ofile.close();
        self.tokens.deinit();
    }
};

test "TranspileProcess init and deinit" {
    const allocator = std.testing.allocator;
    const ifilepath = "TranspileProcess_init_and_deinit.fn";
    const ofilepath = "TranspileProcess_init_and_deinit.c";

    // Create dummy input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        try file.writeAll("dummy input");
    }

    // Initialize TranspileProcess
    var process = try TranspileProcess.init(allocator, ifilepath, ofilepath, .TranspileProcessExec);
    defer process.deinit();

    // Check initial state
    try std.testing.expect(process.flags == .TranspileProcessExec);
    try std.testing.expect(process.pos.line == 1);
    try std.testing.expect(process.pos.col == 1);
    try std.testing.expect(mem.eql(u8, process.pos.filename, ifilepath));
    try std.testing.expect(process.tokens.items.len == 0);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}
