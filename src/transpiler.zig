const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const token = @import("./token.zig");

/// `TranspileProcess` represents the state and configuration of a transpilation process.
pub const TranspileProcess = struct {
    /// `flags` is a set of flags that control the behavior of the transpilation process.
    flags: u8,
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
    pub fn init(allocator: mem.Allocator, ifilepath: []const u8, ofilepath: []const u8, flags: u8) !Self {
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
