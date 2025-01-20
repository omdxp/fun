const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const token = @import("./token.zig");
const ast = @import("./ast.zig");
const misc = @import("./misc.zig");

/// TranspileProcessFlags is an enumeration that defines flags for the transpile process.
pub const TranspileProcessFlags = packed struct {
    /// Flag to indicate execution process.
    exec: bool = false,
    /// Flag to indicate output file process.
    outf: bool = false,
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
    /// `tokens` is a vector of tokens generated from the input file.
    tokens: misc.Vector(token.Token),
    /// `nodes` is a list of AST (Abstract Syntax Tree) nodes.
    /// This vector holds the nodes that are part of the AST being processed by the transpiler.
    nodes: misc.Vector(ast.Node),
    /// The allocator to be used for memory allocation operations.
    allocator: mem.Allocator,

    const Self = @This();

    /// Initializes a new instance of `TranspileProcess`.
    ///
    /// This function opens the input file in read-only mode and creates the output file
    /// with read permissions. It also initializes the token list with the provided allocator.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for memory allocation operations.
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
            .tokens = misc.Vector(token.Token).init(allocator),
            .nodes = misc.Vector(ast.Node).init(allocator),
            .allocator = allocator,
        };
    }

    /// Logs an error message with the current position in the token stream.
    ///
    /// This function logs an error message along with the line number, column number,
    /// and filename where the error occurred, then panics.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `fmt`: The format string for the error message.
    /// - `args`: The arguments for the format string.
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.deinit();
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        std.debug.panic("Error: {s} in {s}:{d}:{d}\n", .{
            msg,
            self.pos.filename,
            self.pos.line,
            self.pos.col,
        });
    }

    /// Logs a warning message with the current position in the token stream.
    ///
    /// This function logs a warning message along with the line number, column number,
    /// and filename where the warning occurred.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `fmt`: The format string for the warning message.
    /// - `args`: The arguments for the format string.
    pub fn warn(self: *Self, fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        std.debug.print("Warning: {s} in {s}:{d}:{d}\n", .{
            msg,
            self.pos.filename,
            self.pos.line,
            self.pos.col,
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
        self.nodes.deinit();
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
    var process = try TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    defer process.deinit();

    // Check initial state
    try std.testing.expect(process.flags.outf);
    try std.testing.expect(process.pos.line == 1);
    try std.testing.expect(process.pos.col == 1);
    try std.testing.expect(mem.eql(u8, process.pos.filename, ifilepath));
    try std.testing.expect(process.tokens.items().len == 0);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}
