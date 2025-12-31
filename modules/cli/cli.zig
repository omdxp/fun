const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const process = std.process;
const Child = std.process.Child;
const codegen = @import("codegen");
const utils = @import("utils");
const builtin = @import("builtin");

/// Errors that can occur during CLI operations.
pub const CliError = error{
    /// Error indicating that the required input file was not provided.
    MissingInputFile,
    /// Error indicating that the required output file was not specified.
    MissingOutputFile,
    /// Error indicating that the input file has an invalid or unsupported extension.
    InvalidInputExtension,
    /// Error indicating that the output file has an invalid or unsupported extension.
    InvalidOutputExtension,
    /// Error indicating that the compilation process failed.
    CompilationFailed,
    /// Error indicating that a C compiler could not be found.
    MissingCCompiler,
    /// Error indicating that the execution process failed.
    ExecutionFailed,
    /// Error indicating that help information should be displayed.
    ShowHelp,
};

/// `CliOptions` represents the command-line options for the transpiler.
/// This structure holds all the configuration options that can be set via command-line arguments.
pub const CliOptions = struct {
    /// The path to the input file that will be transpiled.
    input_file: []const u8,
    /// The path where the output file will be written.
    output_file: []const u8,
    /// Flag to control whether the output should be compiled and executed.
    /// When true, the generated C code will be compiled and run.
    exec: bool,
    /// Flag to control whether to keep the generated .c file.
    /// When true, the .c file will be preserved after execution.
    outf: bool,
    /// Flag to control AST node printing.
    /// When true, the Abstract Syntax Tree nodes will be printed during transpilation.
    print_ast: bool,
};

/// Prints the usage information for the transpiler command-line interface.
///
/// This function writes a formatted help message to the provided writer,
/// describing all available command-line options and their purposes.
///
/// Parameters:
/// - `writer`: The writer interface where the usage information will be written.
///
/// Returns:
/// - Might return an error if writing to the output fails.
fn print_usage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: fun -in <input_file> [-out <output_file>] [-no-exec] [-outf] [-ast] [-help]
        \\
        \\Arguments:
        \\  -in      <file>  Input file to compile (required)
        \\  -out     <file>  Output file (optional, defaults to input filename with .c extension)
        \\  -no-exec         Disable automatic compilation and execution (optional, execution enabled by default)
        \\  -outf            Generate .c output file (optional, disabled by default)
        \\  -ast             Print AST nodes (optional, disabled by default)
        \\  -help            Show this help message
        \\
    );
}

/// Parses command-line arguments and returns a CliOptions structure.
///
/// This function processes the command-line arguments, validates them,
/// and constructs a CliOptions structure with the parsed values.
/// If required arguments are missing or invalid, it prints an error
/// message and usage information, then exits the program.
///
/// Parameters:
/// - `allocator`: The memory allocator to use for string operations.
///
/// Returns:
/// - `CliOptions`: A structure containing all parsed command-line options.
///
/// Errors:
/// - Returns an error if argument parsing or memory allocation fails.
pub fn parse_args(allocator: mem.Allocator) !CliOptions {
    // First check for no arguments
    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        // Skip executable name
        _ = args.skip();
        if (args.next() == null) {
            const stderr = std.io.getStdErr().writer();
            try print_usage(stderr);
            return CliError.ShowHelp;
        }
    }

    // Now parse the actual arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip executable name
    _ = args.skip();

    // NOTE: `argsWithAllocator` can yield slices whose backing storage does not
    // outlive the iterator (platform dependent). Always dupe any argv slices we
    // intend to keep.
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var exec = true;
    var outf = false;
    var print_ast = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-help")) {
            const stderr = std.io.getStdErr().writer();
            try print_usage(stderr);
            return CliError.ShowHelp;
        } else if (std.mem.eql(u8, arg, "-in")) {
            const file = args.next() orelse return CliError.MissingInputFile;
            // Validate file extension
            if (!std.mem.endsWith(u8, file, ".fn")) {
                return CliError.InvalidInputExtension;
            }
            input_file = try allocator.dupe(u8, file);
        } else if (std.mem.eql(u8, arg, "-out")) {
            const file = args.next() orelse return CliError.MissingOutputFile;
            // Validate output file extension
            if (!std.mem.endsWith(u8, file, ".c")) {
                return CliError.InvalidOutputExtension;
            }
            output_file = try allocator.dupe(u8, file);
            outf = true; // When -out is provided, automatically set outf to true
        } else if (std.mem.eql(u8, arg, "-no-exec")) {
            exec = false;
        } else if (std.mem.eql(u8, arg, "-outf")) {
            outf = true;
        } else if (std.mem.eql(u8, arg, "-ast")) {
            print_ast = true;
        }
    }

    const ifilepath = input_file orelse return CliError.MissingInputFile;

    const ofilepath = if (output_file) |path| path else blk: {
        // Create default output path by replacing extension with .c
        const input_path = std.fs.path.basename(ifilepath);
        const extension_index = std.mem.lastIndexOf(u8, input_path, ".");
        if (extension_index) |index| {
            break :blk try std.fmt.allocPrint(allocator, "{s}.c", .{input_path[0..index]});
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}.c", .{input_path});
    };

    return CliOptions{
        .input_file = ifilepath,
        .output_file = ofilepath,
        .exec = exec,
        .outf = outf,
        .print_ast = print_ast,
    };
}

/// Compiles and runs the generated C code.
///
/// This function takes a C source file, compiles it using GCC,
/// executes the resulting binary, and handles the cleanup.
/// It also manages the output and error streams for both
/// compilation and execution phases.
///
/// Parameters:
/// - `allocator`: The memory allocator to use for string operations.
/// - `c_file_or_content`: The path to the C source file or the C code content.
/// - `is_file`: A flag indicating whether `c_file_or_content` is a file path or content.
///
/// Returns:
/// - Might return error.CompilationFailed if GCC compilation fails.
/// - Might return other errors from file operations or process execution.
pub fn compile_and_run(allocator: mem.Allocator, c_file_or_content: []const u8, is_file: bool, input_file: []const u8) !void {
    const input_path = std.fs.path.basename(input_file);
    const extension_index = std.mem.lastIndexOf(u8, input_path, ".");
    var exe_file_name: []const u8 = input_path;
    if (extension_index) |index| {
        exe_file_name = input_path[0..index];
    }

    // In tests, multiple runs can collide on the same output exe/pdb name, and on Windows
    // that can lead to file-lock stalls. Make the output name unique.
    const exe_file_name_owned: ?[]const u8 = if (builtin.is_test)
        try std.fmt.allocPrint(allocator, "{s}_{d}", .{ exe_file_name, std.time.nanoTimestamp() })
    else
        null;
    defer if (exe_file_name_owned) |n| allocator.free(n);
    if (exe_file_name_owned) |n| exe_file_name = n;
    const exe_file = blk: {
        if (builtin.target.os.tag == .windows) {
            break :blk try std.fmt.allocPrint(allocator, "{s}.exe", .{exe_file_name});
        }
        break :blk try allocator.dupe(u8, exe_file_name);
    };
    defer allocator.free(exe_file);
    // Always attempt cleanup even on early returns.
    defer fs.cwd().deleteFile(exe_file) catch {};

    const pdb_file: ?[]const u8 = if (builtin.target.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "{s}.pdb", .{exe_file_name})
    else
        null;
    defer if (pdb_file) |p| allocator.free(p);
    defer if (pdb_file) |p| {
        fs.cwd().deleteFile(p) catch {};
    };

    // When `zig build test` runs tests with `--listen=-`, stdout is used for the
    // test runner protocol. Writing arbitrary output to stdout from tests can
    // corrupt the protocol and appear as a hang.
    const stdout = if (builtin.is_test) std.io.getStdErr().writer() else std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // If content is provided instead of a file, write it to a temporary file first
    var c_path: []const u8 = undefined;
    var temp_name: ?[]const u8 = null;
    if (!is_file) {
        temp_name = try std.fmt.allocPrint(allocator, "temp_{d}.c", .{std.time.timestamp()});
        errdefer if (temp_name) |name| allocator.free(name);

        const temp_file = try fs.cwd().createFile(temp_name.?, .{});
        try temp_file.writeAll(c_file_or_content);
        temp_file.close();

        c_path = temp_name.?;
    } else {
        c_path = c_file_or_content;
    }

    // Make sure to clean up temp file in all cases when it's not a permanent file
    defer if (!is_file and temp_name != null) {
        fs.cwd().deleteFile(temp_name.?) catch {};
        allocator.free(temp_name.?);
    };

    // Compile the C file
    {
        // Use `zig cc` instead of relying on a system `gcc`.
        // NOTE: When `fun` itself is built/tested via Zig, invoking `zig` from within
        // Zig tests can deadlock on shared cache locks. To avoid that, give this nested
        // `zig cc` invocation its own cache directories.
        // IMPORTANT: Do not create/delete a fresh cache tree per call.
        // On Windows this can be extremely slow (or appear hung) due to file locking/AV.
        // Reuse stable cache dirs under the project's .zig-cache.
        const global_cache_dir_rel = ".zig-cache/fun_cli_global_cache";
        const local_cache_dir_rel = ".zig-cache/fun_cli_local_cache";
        try fs.cwd().makePath(global_cache_dir_rel);
        try fs.cwd().makePath(local_cache_dir_rel);

        const global_cache_dir_abs = try fs.cwd().realpathAlloc(allocator, global_cache_dir_rel);
        defer allocator.free(global_cache_dir_abs);
        const local_cache_dir_abs = try fs.cwd().realpathAlloc(allocator, local_cache_dir_rel);
        defer allocator.free(local_cache_dir_abs);

        var env_map = try process.getEnvMap(allocator);
        defer env_map.deinit();
        try env_map.put("ZIG_GLOBAL_CACHE_DIR", global_cache_dir_abs);
        try env_map.put("ZIG_LOCAL_CACHE_DIR", local_cache_dir_abs);

        const cc_args = [_][]const u8{
            "zig",
            "cc",
            "-g0",
            c_path,
            "-o",
            exe_file,
        };
        const result = process.Child.run(.{
            .allocator = allocator,
            .argv = &cc_args,
            .env_map = &env_map,
        }) catch |err| switch (err) {
            error.FileNotFound => return CliError.MissingCCompiler,
            else => return err,
        };
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        if (result.term.Exited != 0) {
            try stderr.print("Compilation error:\n{s}", .{result.stderr});
            return CliError.CompilationFailed;
        }
    }

    // Run the compiled program
    {
        var exe_file_for_os: []const u8 = undefined;
        // Windows requires .\ prefix for executables
        // Linux and MacOS require ./ prefix for executables
        // This is a workaround for the fact that Zig doesn't have a built-in way to check the OS
        // and we don't want to use std.os directly
        if (builtin.target.os.tag == .windows) {
            exe_file_for_os = try std.fmt.allocPrint(allocator, ".\\{s}", .{exe_file});
        } else {
            exe_file_for_os = try std.fmt.allocPrint(allocator, "./{s}", .{exe_file});
        }
        defer allocator.free(exe_file_for_os);

        const result = try process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{exe_file_for_os},
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        if (result.term.Exited != 0) {
            try stderr.print("Runtime error: {s}", .{result.stderr});
            return CliError.ExecutionFailed;
        }

        try stdout.print("{s}", .{result.stdout});
    }

    // Executable cleanup handled via defer above.
}
