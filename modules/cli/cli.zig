const std = @import("std");
const mem = std.mem;
const process = std.process;
const codegen = @import("codegen");
const lexer = @import("lexer");
const token = lexer.token;
const parser = @import("parser");
const utils = @import("utils");
const builtin = @import("builtin");
pub const manifest = @import("manifest.zig");

/// Compatibility shim: ArrayList with embedded allocator (old API style).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

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
    /// Error indicating `fun build` could not find a `fun.toml` manifest in
    /// the current directory.
    ManifestNotFound,
    /// Error indicating `-fuzz-target`/`fun fuzz <path>` was given no name.
    MissingFuzzTarget,
};

/// `CliOptions` represents the command-line options for the transpiler.
/// This structure holds all the configuration options that can be set via command-line arguments.
pub const CliOptions = struct {
    /// The path to the input file that will be transpiled, or the scan root for tree-wide formatter checks.
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

    /// Flag to format the input `.fn` file in-place.
    fmt: bool,

    /// Flag to format the input file and all locally imported modules (skips `std.*`).
    fmt_all: bool,

    /// Flag to format the input `.fn` file in-place AND then run the full compiler
    /// pipeline (reporting diagnostics via stderr). Used by the language server to
    /// combine formatting + diagnostics into a single subprocess invocation.
    fmt_diag: bool,

    /// Flag to check whether the input file is correctly formatted without modifying it.
    /// Exits with code 1 and prints the filename if the file would be changed by formatting.
    fmt_check: bool,

    /// Flag to recursively check all `.fn` files under the current directory or the path given by `-in`.
    fmt_check_all: bool,

    /// Flag to enable debug info: emits `#line` directives in generated C and passes `-g`
    /// to the C compiler so gdb/lldb/sanitizers map back to Fun source locations.
    debug_info: bool,

    /// Flag to emit unused import/variable/function/compound warnings.
    warn_unused: bool,

    /// Like `warn_unused` but lenient: a hard type error elsewhere in the file
    /// does not suppress the unused-* diagnostics (used by fls so squiggles still
    /// appear on files with an unrelated error). Implies `warn_unused`.
    warn_unused_lenient: bool,

    /// Arguments passed to the compiled program (everything after `--`).
    program_args: [][]const u8,

    /// Flag to compile in TEST mode: `test "name" { ... }` blocks are
    /// type-checked/emitted and a generated runner `main` replaces any
    /// user-defined `main`. Set by `-test` or the `fun test <path>`
    /// subcommand form (see `cmd/fun/main.zig`).
    test_mode: bool,

    /// Flag to compile in FUZZ mode: exactly one `fuzz "name" (data, len)
    /// { ... }` block (selected by `fuzz_target`) is type-checked/emitted
    /// as a harness function, replacing any user-defined `main`. Set by
    /// `-fuzz` or the `fun fuzz <path> [target]` subcommand form.
    fuzz_mode: bool,

    /// The specific fuzz target's name to build (see `fuzz_mode`). Set by
    /// `-fuzz-target <name>` or the `fun fuzz <path> <target>` subcommand
    /// form. Required when the file declares more than one `fuzz` block;
    /// auto-selected when there's exactly one.
    fuzz_target: ?[]const u8,
};

pub fn free_options(allocator: mem.Allocator, options: CliOptions) void {
    allocator.free(options.input_file);
    allocator.free(options.output_file);
    for (options.program_args) |arg| allocator.free(arg);
    allocator.free(options.program_args);
    if (options.fuzz_target) |t| allocator.free(t);
}

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
fn print_usage(io: std.Io) void {
    std.Io.File.stderr().writeStreamingAll(io,
        \\Usage:
        \\  fun -in <input_file> [-fmt | -fmt-all | -fmt-diag | -fmt-check | -fmt-check-all] [-out <output_file>] [-no-exec] [-outf] [-ast] [-g] [-warn-unused] [-test] [-fuzz] [-fuzz-target <name>] [-help] [-- <program args...>]
        \\  fun test <input_file>   (shorthand for `fun -in <input_file> -test`)
        \\  fun test [<dir>]        (runs every `test` block under <dir>, default '.'; aggregate summary)
        \\  fun fuzz <input_file> [<target>]   (shorthand for `fun -in <input_file> -fuzz [-fuzz-target <target>]`)
        \\  fun fuzz [<dir>]        (runs every `fuzz` target under <dir> for FUN_FUZZ_DEFAULT_SECONDS each, default '.'/30s)
        \\  fun build               (reads ./fun.toml, installs binaries under fun-out/bin/)
        \\  fun -fmt-check-all [-in <file_or_dir>]
        \\  fun -version
        \\
        \\Arguments:
        \\  -help             Show this help message
        \\  -version          Print version and exit
        \\  -in      <file>   Input file to compile (required except for -fmt-check-all)
        \\  -fmt              Format the input file in-place (optional)
        \\  -fmt-all          Format the input file and all locally imported modules (optional)
        \\  -fmt-diag         Format the input file in-place, then run diagnostics (optional)
        \\  -fmt-check        Check if the input file is formatted; exit 1 if not (optional)
        \\  -fmt-check-all    Check every .fn file under the current directory or -in root; exit 1 if any are unformatted (optional)
        \\  -g                Enable debug info: source-level Fun→C mapping + DWARF symbols (optional)
        \\  -warn-unused      Emit unused import/variable/function/compound warnings (optional)
        \\  -warn-unused-lenient  Like -warn-unused but still emits unused warnings when the file has an unrelated type error (used by fls) (optional)
        \\  -test             Compile `test "name" { ... }` blocks into a runner binary instead of the normal program (optional)
        \\  -fuzz             Compile one `fuzz "name" (data, len) { ... }` block into a fuzzing harness instead of the normal program (optional)
        \\  -fuzz-target <name>  Select which fuzz block to build, when the file declares more than one (optional)
        \\  -out     <file>   Output file (optional, defaults to input filename with .c extension)
        \\  -no-exec          Disable automatic compilation and execution (optional, execution enabled by default)
        \\  -outf             Generate .c output file (optional, disabled by default)
        \\  -ast              Print AST nodes (optional, disabled by default)
        \\  --                All following args are passed to the compiled program
        \\
    ) catch {};
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
pub fn parse_args(allocator: mem.Allocator, io: std.Io, argv: []const []const u8) !CliOptions {
    // argv is everything after the executable name.
    if (argv.len == 0) {
        print_usage(io);
        return CliError.ShowHelp;
    }

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var exec = true;
    var outf = false;
    var print_ast = false;
    var fmt = false;
    var fmt_all = false;
    var fmt_diag = false;
    var fmt_check = false;
    var fmt_check_all = false;
    var debug_info = false;
    var warn_unused = false;
    var warn_unused_lenient = false;
    var test_mode = false;
    var fuzz_mode = false;
    var fuzz_target: ?[]const u8 = null;
    errdefer if (fuzz_target) |t| allocator.free(t);
    var program_args = ArrayList([]const u8).init(allocator);
    errdefer {
        for (program_args.items) |p| allocator.free(p);
        program_args.deinit();
    }

    var i: usize = 0;
    while (i < argv.len) {
        const arg = argv[i];
        i += 1;
        if (std.mem.eql(u8, arg, "--")) {
            while (i < argv.len) {
                try program_args.append(try allocator.dupe(u8, argv[i]));
                i += 1;
            }
            break;
        }
        if (std.mem.eql(u8, arg, "-help")) {
            print_usage(io);
            return CliError.ShowHelp;
        } else if (std.mem.eql(u8, arg, "-in")) {
            if (i >= argv.len) return CliError.MissingInputFile;
            const file = argv[i];
            i += 1;
            input_file = try allocator.dupe(u8, file);
        } else if (std.mem.eql(u8, arg, "-out")) {
            if (i >= argv.len) return CliError.MissingOutputFile;
            const file = argv[i];
            i += 1;
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
        } else if (std.mem.eql(u8, arg, "-fmt")) {
            fmt = true;
        } else if (std.mem.eql(u8, arg, "-fmt-all")) {
            fmt_all = true;
        } else if (std.mem.eql(u8, arg, "-fmt-diag")) {
            fmt_diag = true;
        } else if (std.mem.eql(u8, arg, "-fmt-check")) {
            fmt_check = true;
        } else if (std.mem.eql(u8, arg, "-fmt-check-all")) {
            fmt_check_all = true;
        } else if (std.mem.eql(u8, arg, "-g")) {
            debug_info = true;
        } else if (std.mem.eql(u8, arg, "-warn-unused")) {
            warn_unused = true;
        } else if (std.mem.eql(u8, arg, "-warn-unused-lenient")) {
            warn_unused = true;
            warn_unused_lenient = true;
        } else if (std.mem.eql(u8, arg, "-test")) {
            test_mode = true;
        } else if (std.mem.eql(u8, arg, "-fuzz")) {
            fuzz_mode = true;
        } else if (std.mem.eql(u8, arg, "-fuzz-target")) {
            if (i >= argv.len) return CliError.MissingFuzzTarget;
            const name = argv[i];
            i += 1;
            if (fuzz_target) |old| allocator.free(old);
            fuzz_target = try allocator.dupe(u8, name);
        }
    }

    const ifilepath = input_file orelse blk: {
        if (fmt_check_all) break :blk try allocator.dupe(u8, ".");
        return CliError.MissingInputFile;
    };

    if (!fmt_check_all and !std.mem.endsWith(u8, ifilepath, ".fn")) {
        return CliError.InvalidInputExtension;
    }

    const ofilepath = if (output_file) |path| path else if (fmt_check_all)
        try allocator.dupe(u8, "")
    else blk: {
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
        .fmt = fmt,
        .fmt_all = fmt_all,
        .fmt_diag = fmt_diag,
        .fmt_check = fmt_check,
        .fmt_check_all = fmt_check_all,
        .debug_info = debug_info,
        .warn_unused = warn_unused,
        .warn_unused_lenient = warn_unused_lenient,
        .program_args = try program_args.toOwnedSlice(),
        .test_mode = test_mode,
        .fuzz_mode = fuzz_mode,
        .fuzz_target = fuzz_target,
    };
}

fn dir_exists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
        dir.close(io);
        return true;
    }

    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn should_skip_fmt_check_dir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".funsand") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "build") or
        std.mem.eql(u8, name, "zig-out");
}

fn collect_fun_files_recursive(
    allocator: mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    out: *ArrayList([]const u8),
) !void {
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (should_skip_fmt_check_dir(entry.name)) continue;
                const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child_path);
                try collect_fun_files_recursive(allocator, io, child_path, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".fn")) continue;
                try out.append(try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
            },
            else => {},
        }
    }
}

fn fmt_check_root_path(allocator: mem.Allocator, io: std.Io, input_path: []const u8) ![]const u8 {
    if (dir_exists(io, input_path)) {
        return allocator.dupe(u8, input_path);
    }

    if (std.mem.endsWith(u8, input_path, ".fn")) {
        const parent = std.fs.path.dirname(input_path) orelse ".";
        return allocator.dupe(u8, parent);
    }

    return allocator.dupe(u8, input_path);
}

const FmtTopLevelGroup = enum {
    imports,
    globals,
};

fn warning_control_group_for_tokens(tokens: []const token.Token, start_idx: usize) ?FmtTopLevelGroup {
    if (start_idx + 1 >= tokens.len) return null;
    const keyword = tokens[start_idx];
    if (keyword.type != .Keyword) return null;
    const kw = keyword.data.sval.items;
    if (!std.mem.eql(u8, kw, "allow") and !std.mem.eql(u8, kw, "expect")) return null;

    const id_tok = tokens[start_idx + 1];
    if (id_tok.type != .Identifier) return null;
    const id = id_tok.data.sval.items;

    if (std.mem.eql(u8, id, "unused_import")) return .imports;
    if (std.mem.eql(u8, id, "unused_variable")) return .globals;
    return null;
}

pub fn free_owned_paths(allocator: mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// True when a directory exists at `path` (vs. a file, or nothing at all).
/// Exposed so `cmd/fun/main.zig` can tell `fun test <path>`/`fun fuzz <path>`
/// (directory/whole-project form) apart from the single-file form before
/// committing to either pipeline.
pub fn is_directory(io: std.Io, path: []const u8) bool {
    return dir_exists(io, path);
}

/// Every `.fn` file under `root`, sorted, skipping the same build-artifact
/// directories `-fmt-check-all` skips.
fn collect_all_fun_files(allocator: mem.Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var files = ArrayList([]const u8).init(allocator);
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit();
    }
    try collect_fun_files_recursive(allocator, io, root, &files);
    std.sort.pdq([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return files.toOwnedSlice();
}

/// True when `path` declares at least one top-level `keyword "name" {`/`(`
/// block (`keyword` is `"test"` or `"fuzz"`, both lexer keywords). A
/// lightweight token scan rather than a real parse: a `test`/`fuzz`
/// keyword token immediately followed by a string literal doesn't occur
/// any other way in valid Fun source, so the shape alone is enough to
/// decide whether a file belongs in a directory-wide run without paying
/// for a full parse of every file just to filter the list. Any lex
/// failure (the file will fail to compile anyway) is treated as "doesn't
/// declare one" -- the real run below reports the actual error.
fn declares_top_level_block(allocator: mem.Allocator, path: []const u8, keyword: []const u8) bool {
    var tp = codegen.TranspileProcess.init_rw(allocator, path, "__scan_unused__.c", .{ .exec = false, .outf = false, .ast = false }) catch return false;
    defer tp.deinit();
    var lp = lexer.LexProcess.init(&tp);
    defer lp.deinit();
    lp.lex() catch return false;

    const tokens = tp.tokens.items();
    var i: usize = 0;
    while (i + 1 < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type != .Keyword) continue;
        if (!mem.eql(u8, t.data.sval.items, keyword)) continue;
        if (tokens[i + 1].type == .String) return true;
    }
    return false;
}

/// Compiles and runs `path` in `test` mode, reusing one fixed temp `.c` name
/// across the whole suite (runs are sequential, never concurrent). Any
/// failure -- a lex/parse/transpile error, a missing C compiler, or the
/// compiled test binary itself exiting nonzero -- surfaces as a returned
/// error rather than exiting the process, so `run_test_suite`'s loop can
/// count it and move on to the next file.
fn run_one_test_file(allocator: mem.Allocator, io: std.Io, path: []const u8, debug_info: bool) !void {
    const out_c_path = "fun_test_suite_run.c";
    defer std.Io.Dir.cwd().deleteFile(io, out_c_path) catch {};

    var tp = try codegen.TranspileProcess.init(allocator, path, out_c_path, .{
        .exec = false,
        .outf = true,
        .debug_info = debug_info,
        .test_mode = true,
    });
    var lp = lexer.LexProcess.init(&tp);
    var pp = parser.ParseProcess.init(&tp);
    defer {
        lp.deinit();
        tp.deinit();
    }
    try lp.lex();
    try pp.parse();
    try tp.transpile();

    try compile_and_run_ex(allocator, io, out_c_path, true, path, &.{}, debug_info, false, false);
}

/// `fun test <dir>` / `fun test` (no path): discovers every `.fn` file under
/// `root` that declares a `test` block, runs each in its own fresh compile
/// pass, and prints an aggregate pass/fail summary. Returns
/// `CliError.ExecutionFailed` if any file failed, so the process exit code
/// stays shell-script-friendly the same way a single `fun test <file>` is.
pub fn run_test_suite(allocator: mem.Allocator, io: std.Io, root: []const u8, debug_info: bool) !void {
    const files = try collect_all_fun_files(allocator, io, root);
    defer free_owned_paths(allocator, files);

    const stdout = std.Io.File.stdout();
    var passed: usize = 0;
    var failed: usize = 0;
    for (files) |path| {
        if (!declares_top_level_block(allocator, path, "test")) continue;

        var hdr_buf: [1024]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "== {s} ==\n", .{path}) catch "==\n";
        stdout.writeStreamingAll(io, hdr) catch {};

        run_one_test_file(allocator, io, path, debug_info) catch |err| {
            // `ExecutionFailed` means the compiled test binary itself ran
            // and reported failures -- its own `test: <name> ... FAIL`
            // lines already said so, so naming the error again here would
            // just repeat the same fact in a less useful form. Any other
            // error (a lex/parse/transpile failure, a missing C compiler)
            // never got its own message, so it's reported here.
            if (err != CliError.ExecutionFailed) {
                var ebuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&ebuf, "error: {s}\n", .{@errorName(err)}) catch "error\n";
                stdout.writeStreamingAll(io, msg) catch {};
            }
            failed += 1;
            continue;
        };
        passed += 1;
    }

    if (passed + failed == 0) {
        var nbuf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&nbuf, "no `test` blocks found under {s}\n", .{root}) catch "no test blocks found\n";
        stdout.writeStreamingAll(io, msg) catch {};
        return;
    }

    var summary_buf: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "\n{d}/{d} test files passed\n", .{ passed, passed + failed }) catch "done\n";
    stdout.writeStreamingAll(io, summary) catch {};

    // Exit directly with a plain nonzero code rather than returning an
    // error for `cmd/fun/main.zig` to report -- the summary just printed
    // already says what happened; a generic "Error: ..." line under it
    // would only repeat that in a less useful form (matches how a single
    // failing `fun test <file.fn>` exits: nonzero, no extra banner).
    if (failed > 0) std.process.exit(1);
}

/// Every `fuzz "<name>" (...)` target `path` declares, in source order. A
/// file can declare more than one; the directory-wide fuzz runner builds
/// and runs each separately (a fuzz harness only ever exercises one target
/// per binary, selected at compile time by `-fuzz-target`).
fn collect_fuzz_targets(allocator: mem.Allocator, path: []const u8) ![]const []const u8 {
    var targets = ArrayList([]const u8).init(allocator);
    errdefer {
        for (targets.items) |t| allocator.free(t);
        targets.deinit();
    }

    var tp = codegen.TranspileProcess.init_rw(allocator, path, "__scan_unused__.c", .{ .exec = false, .outf = false, .ast = false }) catch return targets.toOwnedSlice();
    defer tp.deinit();
    var lp = lexer.LexProcess.init(&tp);
    defer lp.deinit();
    lp.lex() catch return targets.toOwnedSlice();

    const tokens = tp.tokens.items();
    var i: usize = 0;
    while (i + 1 < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type != .Keyword or !mem.eql(u8, t.data.sval.items, "fuzz")) continue;
        if (tokens[i + 1].type != .String) continue;
        try targets.append(try allocator.dupe(u8, tokens[i + 1].data.sval.items));
    }
    return targets.toOwnedSlice();
}

/// Default wall-clock budget (seconds) for one fuzz target when running the
/// directory-wide `fun fuzz [path]` form, where multiple targets across
/// possibly multiple files each get their own bounded run rather than the
/// open-ended campaign a single `fun fuzz <file.fn> <target>` normally
/// leaves to the caller. Short enough to keep a whole project's fuzz suite
/// bounded in CI, long enough to be a real regression check rather than a
/// no-op. Override with `FUN_FUZZ_DEFAULT_SECONDS`.
const default_fuzz_seconds: u32 = 30;

fn fuzz_budget_seconds() u32 {
    if (std.c.getenv("FUN_FUZZ_DEFAULT_SECONDS")) |z| {
        const s = mem.sliceTo(z, 0);
        if (s.len > 0) {
            if (std.fmt.parseInt(u32, s, 10) catch null) |v| return v;
        }
    }
    return default_fuzz_seconds;
}

/// Runs `argv` (index 0 is the executable) to completion, sending SIGKILL
/// if it's still running after `budget_seconds`. Deliberately does NOT use
/// `std.process.Child.kill` from the watchdog thread while `wait` runs on
/// this one: `Child.kill` on POSIX reaps the process itself (its own
/// `wait4` call), and so does `Child.wait` -- calling both concurrently on
/// the same pid from two threads is a real double-reap race (confirmed by
/// reading the standard library's own POSIX implementation: the loser's
/// `wait4` gets ECHILD, which its own code path is labeled "Double-free"
/// and treated as a bug). The watchdog thread here only ever sends a raw
/// signal via `std.posix.kill`, which does not reap; the actual `wait` (the
/// only call that reaps) stays solely on this function's own thread. POSIX
/// only -- on Windows the budget isn't enforced, matching the fuzzing
/// feature's existing best-effort Windows support elsewhere in this file.
const BoundedRunResult = struct {
    term: std.process.Child.Term,
    // True when the watchdog itself force-terminated the process because
    // `budget_seconds` elapsed -- expected, successful completion of a
    // time-bounded run, NOT a crash. The caller must check this before
    // treating a nonzero/signal `term` as a real failure: a `SIGKILL` term
    // caused by hitting the budget looks identical, in `term` alone, to one
    // caused by an actual crash.
    killed_by_budget: bool,
};

fn spawn_and_wait_bounded(io: std.Io, argv: []const []const u8, budget_seconds: u32) !BoundedRunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    if (builtin.target.os.tag == .windows) {
        return .{ .term = try child.wait(io), .killed_by_budget = false };
    }

    const WatchdogCtx = struct {
        pid: std.posix.pid_t,
        budget_seconds: u32,
        done: std.atomic.Value(bool),
        killed: std.atomic.Value(bool),
    };
    var ctx = WatchdogCtx{
        .pid = child.id.?,
        .budget_seconds = budget_seconds,
        .done = std.atomic.Value(bool).init(false),
        .killed = std.atomic.Value(bool).init(false),
    };
    const watchdog = std.Thread.spawn(.{}, struct {
        // A plain libc `usleep` rather than any `std.Io`-based sleep: this
        // runs on a bare OS thread this function spawned itself, outside
        // whatever event loop `io` belongs to, and pairing it with that
        // event loop's own sleep primitive is untested territory. `usleep`
        // has no such dependency.
        extern "c" fn usleep(usec: c_uint) c_int;

        fn run(c: *WatchdogCtx) void {
            var slept: u32 = 0;
            while (slept < c.budget_seconds and !c.done.load(.acquire)) {
                _ = usleep(1_000_000);
                slept += 1;
            }
            if (!c.done.load(.acquire)) {
                c.killed.store(true, .release);
                std.posix.kill(c.pid, .KILL) catch {};
            }
        }
    }.run, .{&ctx}) catch null;

    const term = try child.wait(io);
    ctx.done.store(true, .release);
    if (watchdog) |t| t.join();
    return .{ .term = term, .killed_by_budget = ctx.killed.load(.acquire) };
}

/// Compiles `path`'s `target` fuzz harness and runs it for `budget_seconds`.
/// Also passes libFuzzer's own `-max_total_time` (a well-behaved libFuzzer
/// build stops on its own), but the real enforcement is
/// `spawn_and_wait_bounded`'s watchdog -- `-max_total_time` was observed
/// NOT to reliably stop a run in every environment (confirmed directly: a
/// hand-compiled libFuzzer binary invoked with no `fun` code involved at
/// all still ran well past its budget in this sandbox), so a directory-wide
/// sweep can't depend on it alone without risking exactly the unbounded
/// hang this feature exists to avoid. Reuses one fixed temp `.c`/exe name
/// across the whole suite (runs are sequential, never concurrent). Any
/// failure -- a lex/parse/transpile error, a missing fuzzing-capable C
/// compiler, or the harness itself finding a crash -- surfaces as a
/// returned error rather than exiting the process.
fn run_one_fuzz_target(allocator: mem.Allocator, io: std.Io, path: []const u8, target: []const u8, debug_info: bool, budget_seconds: u32) !void {
    const out_c_path = "fun_fuzz_suite_run.c";
    defer std.Io.Dir.cwd().deleteFile(io, out_c_path) catch {};

    var tp = try codegen.TranspileProcess.init(allocator, path, out_c_path, .{
        .exec = false,
        .outf = true,
        .debug_info = debug_info,
        .fuzz_mode = true,
    });
    tp.fuzz_target = target;
    var lp = lexer.LexProcess.init(&tp);
    var pp = parser.ParseProcess.init(&tp);
    defer {
        lp.deinit();
        tp.deinit();
    }
    try lp.lex();
    try pp.parse();
    try tp.transpile();

    const exe_file = if (builtin.target.os.tag == .windows) "fun_fuzz_suite_run.exe" else "fun_fuzz_suite_run";
    defer std.Io.Dir.cwd().deleteFile(io, exe_file) catch {};
    try invoke_fuzz_compiler_to_exe(allocator, io, out_c_path, exe_file, debug_info);

    const exe_for_os = if (builtin.target.os.tag == .windows) ".\\fun_fuzz_suite_run.exe" else "./fun_fuzz_suite_run";
    var arg_buf: [64]u8 = undefined;
    const time_arg = try std.fmt.bufPrint(&arg_buf, "-max_total_time={d}", .{budget_seconds});
    const result = try spawn_and_wait_bounded(io, &.{ exe_for_os, time_arg }, budget_seconds);
    // A watchdog kill just means the budget ran out with nothing found --
    // the expected, successful outcome of a bounded sweep, not a crash. Only
    // a term the process reached ON ITS OWN (whether libFuzzer's own
    // `-max_total_time` firing, or an actual crash) reflects a real result.
    if (result.killed_by_budget) return;
    switch (result.term) {
        .exited => |code| if (code != 0) return CliError.ExecutionFailed,
        else => return CliError.ExecutionFailed,
    }
}

/// `fun fuzz <dir>` / `fun fuzz` (no path): discovers every `.fn` file
/// under `root` that declares one or more `fuzz` targets, runs each target
/// for a bounded `FUN_FUZZ_DEFAULT_SECONDS` (default 30s), and prints an
/// aggregate summary. Unlike `fun fuzz <file.fn> <target>`'s open-ended
/// single-target run, this form exists for CI-style "did anything
/// regress" sweeps across a whole project, so every target gets the same
/// short, bounded budget rather than running indefinitely.
pub fn run_fuzz_suite(allocator: mem.Allocator, io: std.Io, root: []const u8, debug_info: bool) !void {
    const files = try collect_all_fun_files(allocator, io, root);
    defer free_owned_paths(allocator, files);

    const budget = fuzz_budget_seconds();
    const stdout = std.Io.File.stdout();
    var ran: usize = 0;
    var failed: usize = 0;
    for (files) |path| {
        if (!declares_top_level_block(allocator, path, "fuzz")) continue;
        const targets = try collect_fuzz_targets(allocator, path);
        defer free_owned_paths(allocator, targets);

        for (targets) |target| {
            var hdr_buf: [1024]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "== {s} :: {s} ({d}s) ==\n", .{ path, target, budget }) catch "==\n";
            stdout.writeStreamingAll(io, hdr) catch {};

            run_one_fuzz_target(allocator, io, path, target, debug_info, budget) catch |err| {
                var ebuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&ebuf, "error: {s}\n", .{@errorName(err)}) catch "error\n";
                stdout.writeStreamingAll(io, msg) catch {};
                failed += 1;
                ran += 1;
                continue;
            };
            ran += 1;
        }
    }

    if (ran == 0) {
        var nbuf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&nbuf, "no `fuzz` targets found under {s}\n", .{root}) catch "no fuzz targets found\n";
        stdout.writeStreamingAll(io, msg) catch {};
        return;
    }

    var summary_buf: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "\n{d}/{d} fuzz targets clean\n", .{ ran - failed, ran }) catch "done\n";
    stdout.writeStreamingAll(io, summary) catch {};

    if (failed > 0) std.process.exit(1);
}

pub fn collect_unformatted_fun_files(allocator: mem.Allocator, io: std.Io, input_path: []const u8) ![]const []const u8 {
    const root_path = try fmt_check_root_path(allocator, io, input_path);
    defer allocator.free(root_path);

    var files = ArrayList([]const u8).init(allocator);
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit();
    }
    try collect_fun_files_recursive(allocator, io, root_path, &files);

    std.sort.pdq([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var offenders = ArrayList([]const u8).init(allocator);
    errdefer {
        for (offenders.items) |path| allocator.free(path);
        offenders.deinit();
    }

    for (files.items) |path| {
        if (try format_file_check(allocator, io, path)) {
            allocator.free(path);
            continue;
        }
        try offenders.append(path);
    }
    files.deinit();

    return offenders.toOwnedSlice();
}

fn build_full_import_path_for_formatter(allocator: mem.Allocator, input_file_path: []const u8, import_path: []const u8) ![]const u8 {
    var file_path = ArrayList(u8).init(allocator);
    defer file_path.deinit();

    const dir_path = std.fs.path.dirname(input_file_path) orelse ".";
    try file_path.appendSlice(dir_path);
    try file_path.append('/');

    // Convert dotted imports to a path. Additionally, support parent traversal via dot runs:
    // - `.`  => path separator
    // - `..` => `../` (one parent)
    // - `....` => `../../` (two parents)
    var i: usize = 0;
    while (i < import_path.len) {
        if (import_path[i] != '.') {
            try file_path.append(import_path[i]);
            i += 1;
            continue;
        }

        var j = i;
        while (j < import_path.len and import_path[j] == '.') : (j += 1) {}
        const run_len = j - i;
        const parents = run_len / 2;
        const sep = (run_len % 2) == 1;

        var p: usize = 0;
        while (p < parents) : (p += 1) {
            try file_path.appendSlice("..");
            try file_path.append('/');
        }
        if (sep) {
            try file_path.append('/');
        }

        i = j;
    }
    try file_path.appendSlice(".fn");

    return file_path.toOwnedSlice();
}

fn freeOwnedStringMap(allocator: mem.Allocator, map: *std.StringHashMap(void)) void {
    var it = map.keyIterator();
    while (it.next()) |k| {
        allocator.free(k.*);
    }
    map.deinit();
}

fn parse_local_import_paths(allocator: mem.Allocator, input_file: []const u8) !ArrayList([]const u8) {
    var result = ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |p| allocator.free(p);
        result.deinit();
    }

    var tp = try codegen.TranspileProcess.init(
        allocator,
        input_file,
        "__fmt_unused__.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();
    var lp = lexer.LexProcess.init(&tp);
    defer lp.deinit();
    try lp.lex();

    const tokens = tp.tokens.items();
    var brace_depth: isize = 0;
    var paren_depth: isize = 0;
    var bracket_depth: isize = 0;
    var can_start_stmt = true;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type == .NewLine) continue;
        if (t.type == .Comment) continue;

        const is_top = brace_depth == 0;
        const is_stmt_start = is_top and paren_depth == 0 and bracket_depth == 0 and can_start_stmt;

        if (is_stmt_start and t.type == .Keyword and std.mem.eql(u8, t.data.sval.items, "imp")) {
            // Parse `imp foo.bar;`
            var j: usize = i + 1;
            while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}

            const isDotRunOperator = struct {
                fn call(tt: token.Token) bool {
                    if (tt.type != .Operator) return false;
                    const s = tt.data.sval.items;
                    if (s.len == 0) return false;
                    for (s) |ch| if (ch != '.') return false;
                    return true;
                }
            }.call;

            var leading_dots: usize = 0;
            while (j < tokens.len) {
                const tj = tokens[j];
                if (!isDotRunOperator(tj)) break;
                leading_dots += tj.data.sval.items.len;
                j += 1;
                while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}
            }

            if (leading_dots % 2 != 0) {
                // Malformed parent traversal (odd dot count). Ignore; compiler will report.
                continue;
            }

            if (j >= tokens.len or tokens[j].type != .Identifier) {
                // Let the normal compiler path handle detailed errors; formatter just ignores malformed imports.
                continue;
            }

            var import_name = ArrayList(u8).init(allocator);
            defer import_name.deinit();
            if (leading_dots > 0) try import_name.appendNTimes('.', leading_dots);
            try import_name.appendSlice(tokens[j].data.sval.items);
            j += 1;

            while (true) {
                while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}
                if (j >= tokens.len) break;
                if (!isDotRunOperator(tokens[j])) break;
                const dot_op = tokens[j].data.sval.items;
                j += 1;

                while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}
                if (j >= tokens.len or tokens[j].type != .Identifier) break;
                try import_name.appendSlice(dot_op);
                try import_name.appendSlice(tokens[j].data.sval.items);
                j += 1;
            }

            // Optional alias: `imp foo.bar as baz;`
            while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}
            if (j < tokens.len and tokens[j].type == .Keyword and std.mem.eql(u8, tokens[j].data.sval.items, "as")) {
                j += 1;
                while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}
                if (j < tokens.len and tokens[j].type == .Identifier) {
                    j += 1;
                }
            }

            const imp_path = try import_name.toOwnedSlice();
            if (!std.mem.startsWith(u8, imp_path, "std.")) {
                try result.append(imp_path);
            } else {
                allocator.free(imp_path);
            }

            i = j;
            can_start_stmt = true;
            continue;
        }

        // Track depth/boundaries.
        if (t.type == .Operator) {
            if (std.mem.eql(u8, t.data.sval.items, "(")) paren_depth += 1;
            if (std.mem.eql(u8, t.data.sval.items, "[")) bracket_depth += 1;
        }
        if (t.type == .Symbol) {
            if (t.data.cval == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            }
            if (t.data.cval == ']') {
                if (bracket_depth > 0) bracket_depth -= 1;
            }
            if (t.data.cval == '{') brace_depth += 1;
            if (t.data.cval == '}' and brace_depth > 0) brace_depth -= 1;

            if (t.data.cval == ';' and brace_depth == 0) {
                can_start_stmt = true;
            } else if (t.data.cval == '}' and brace_depth == 0) {
                can_start_stmt = true;
            } else if (t.data.cval != ';') {
                can_start_stmt = false;
            }
        } else {
            can_start_stmt = false;
        }
    }

    return result;
}

fn format_file_and_imports_recursive(
    allocator: mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    visiting: *std.StringHashMap(void),
    visited: *std.StringHashMap(void),
) !void {
    const canonical = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(io, file_path, &buf);
        break :blk try allocator.dupe(u8, buf[0..n]);
    };
    errdefer allocator.free(canonical);

    if (visited.contains(canonical)) {
        allocator.free(canonical);
        return;
    }
    if (visiting.contains(canonical)) {
        // Cycle detected; stop recursion.
        allocator.free(canonical);
        return;
    }

    // Store owned canonical path in `visiting`.
    try visiting.put(canonical, {});

    // Format current file.
    try format_file_in_place(allocator, io, canonical);

    // Discover local imports and recurse.
    var imports = try parse_local_import_paths(allocator, canonical);
    defer {
        for (imports.items) |p| allocator.free(p);
        imports.deinit();
    }

    for (imports.items) |imp| {
        const rel = try build_full_import_path_for_formatter(allocator, canonical, imp);
        defer allocator.free(rel);
        try format_file_and_imports_recursive(allocator, io, rel, visiting, visited);
    }

    // Move from visiting -> visited.
    _ = visiting.remove(canonical);
    try visited.put(canonical, {});
}

pub fn format_file_and_imports_in_place(allocator: mem.Allocator, io: std.Io, input_file: []const u8) !void {
    var visiting = std.StringHashMap(void).init(allocator);
    defer freeOwnedStringMap(allocator, &visiting);

    var visited = std.StringHashMap(void).init(allocator);
    defer freeOwnedStringMap(allocator, &visited);

    try format_file_and_imports_recursive(allocator, io, input_file, &visiting, &visited);
}

/// Re-indents a multi-line raw string's own CONTINUATION lines (every
/// backtick-prefixed line after the first) to `target_indent` spaces,
/// discarding whatever leading whitespace each one had verbatim from
/// source. Safe: the lexer strips a continuation line's leading
/// whitespace/tabs before its own backtick when RE-reading the string
/// (see `token_make_raw_string`'s multi-line loop), so that whitespace
/// was never part of the string's actual value -- only ever a visual
/// artifact of wherever the line happened to be typed. Leaving it as
/// verbatim-reproduced (the previous behavior) meant a raw string's
/// FIRST line -- freshly positioned by whatever wrapping/indent
/// decision this formatting pass just made for it -- could end up at
/// a totally different column than its own continuation lines, which
/// just kept whatever indentation they'd had in the ORIGINAL source.
/// A single-line (or already-consistently-indented multi-line, e.g.
/// nothing to change) raw string's `text` is returned unchanged
/// (dupe'd, so the caller can always `free` the result uniformly).
fn reindentRawStringContinuations(allocator: mem.Allocator, text: []const u8, target_indent: usize) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\n') == null) {
        return allocator.dupe(u8, text);
    }
    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) {
            try out.append('\n');
            try out.appendNTimes(' ', target_indent);
            var k: usize = 0;
            while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
            try out.appendSlice(line[k..]);
        } else {
            try out.appendSlice(line);
        }
        first = false;
    }
    return out.toOwnedSlice();
}

fn token_text(allocator: mem.Allocator, t: token.Token, source: []const u8, line_starts: []const usize) ![]const u8 {
    return switch (t.type) {
        .Identifier, .Keyword, .Operator => allocator.dupe(u8, t.data.sval.items),
        .Symbol => blk: {
            var buf: [1]u8 = .{t.data.cval};
            break :blk allocator.dupe(u8, buf[0..]);
        },
        .Number => {
            // Preserve the original numeric lexeme exactly as written (e.g. `3.0`, `2.00`, suffixes)
            // so formatting does not change inferred literal intent.
            const start = pos_to_index(line_starts, t.pos, false);
            const end_excl = pos_to_index(line_starts, t.pos, true);
            if (start <= end_excl and end_excl <= source.len and end_excl > start) {
                const raw = source[start..end_excl];
                const lit = std.mem.trim(u8, raw, " \t\r\n");
                if (lit.len > 0) return allocator.dupe(u8, lit);
            }

            // Note: char literals are currently tokenized as Number with `cval`.
            if (t.data == .cval) {
                const c = t.data.cval;
                var out = ArrayList(u8).init(allocator);
                errdefer out.deinit();

                try out.append('\'');
                switch (c) {
                    '\\' => try out.appendSlice("\\\\"),
                    '\'' => try out.appendSlice("\\\'"),
                    '\n' => try out.appendSlice("\\n"),
                    '\r' => try out.appendSlice("\\r"),
                    '\t' => try out.appendSlice("\\t"),
                    0 => try out.appendSlice("\\0"),
                    else => {
                        if (c < 0x20 or c >= 0x7f) {
                            const esc = try std.fmt.allocPrint(allocator, "\\x{x:0>2}", .{c});
                            defer allocator.free(esc);
                            try out.appendSlice(esc);
                        } else {
                            try out.append(c);
                        }
                    },
                }
                try out.append('\'');
                return out.toOwnedSlice();
            }

            const base = switch (t.data) {
                .dnum => try std.fmt.allocPrint(allocator, "{d}", .{t.data.dnum}),
                .llnum => try std.fmt.allocPrint(allocator, "{d}", .{t.data.llnum}),
                .lnum => try std.fmt.allocPrint(allocator, "{d}", .{t.data.lnum}),
                .inum => try std.fmt.allocPrint(allocator, "{d}", .{t.data.inum}),
                else => try allocator.dupe(u8, "0"),
            };
            errdefer allocator.free(base);

            if (t.num == null) return base;
            return switch (t.num.?.type) {
                .Normal => base,
                .Long => std.mem.concat(allocator, u8, &.{ base, "L" }) catch |e| {
                    allocator.free(base);
                    return e;
                },
                .Float => std.mem.concat(allocator, u8, &.{ base, "f" }) catch |e| {
                    allocator.free(base);
                    return e;
                },
                else => base,
            };
        },
        .String => blk: {
            if (t.is_raw_string) {
                // Reproduce the original backtick spelling verbatim (source
                // slice, like Number's literal lexeme above) -- `t.data.sval`
                // holds the LITERAL, already-decoded bytes, not something
                // that can be safely requoted as `"..."` the way a regular
                // string's escape-preserving buffer can (a raw string may
                // contain an unescaped `"` or a real newline, either of
                // which would corrupt or fail to re-lex as a regular
                // string).
                const start = pos_to_index(line_starts, t.pos, false);
                const end_excl = pos_to_index(line_starts, t.pos, true);
                if (start <= end_excl and end_excl <= source.len and end_excl > start) {
                    break :blk allocator.dupe(u8, source[start..end_excl]);
                }
            }
            break :blk std.fmt.allocPrint(allocator, "\"{s}\"", .{t.data.sval.items});
        },
        .Boolean => allocator.dupe(u8, if (t.data.bval) "true" else "false"),
        .Comment => blk: {
            // Always emit exactly one space after //
            const trimmed = std.mem.trim(u8, t.data.sval.items, " \t");
            const out = try std.fmt.allocPrint(allocator, "// {s}", .{trimmed});
            break :blk out;
        },
        .NewLine => allocator.dupe(u8, "\n"),
    };
}

fn is_closing_symbol(c: u8) bool {
    return c == ')' or c == ']';
}

fn is_word_like(t: token.Token) bool {
    return switch (t.type) {
        .Identifier, .Keyword, .Number, .String, .Boolean => true,
        else => false,
    };
}

fn operator_needs_spaces(op: []const u8) bool {
    // Operators that should not be surrounded by spaces are handled separately by symbols.
    // Keep this conservative.
    // Dot runs are treated like access operators and should be glued: `.`, `..`, `...`, etc.
    for (op) |ch| {
        if (ch != '.') break;
    } else {
        return false;
    }
    return !std.mem.eql(u8, op, ",") and
        !std.mem.eql(u8, op, ":") and
        !std.mem.eql(u8, op, "(") and
        !std.mem.eql(u8, op, "[");
}

fn is_builtin_type_keyword(kw: []const u8) bool {
    return utils.keyword_is_datatype(kw);
}

fn isLikelyTypeToken(t: token.Token) bool {
    return switch (t.type) {
        .Keyword => is_builtin_type_keyword(t.data.sval.items),
        .Identifier => (t.data.sval.items.len > 0 and (t.data.sval.items[0] >= 'A' and t.data.sval.items[0] <= 'Z')) or utils.keyword_is_datatype(t.data.sval.items),
        else => false,
    };
}

fn nextSignificantIndex(toks: []const token.Token, start_at: usize) ?usize {
    var i: usize = start_at;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return i;
    }
    return null;
}

fn nextSignificantToken(toks: []const token.Token, start_at: usize) ?token.Token {
    const idx = nextSignificantIndex(toks, start_at) orelse return null;
    return toks[idx];
}

fn isForLoopColonContext(toks: []const token.Token, colon_idx: usize) bool {
    if (colon_idx >= toks.len) return false;
    const colon = toks[colon_idx];
    const is_colon = switch (colon.type) {
        .Symbol => colon.data.cval == ':',
        .Operator => std.mem.eql(u8, colon.data.sval.items, ":"),
        else => false,
    };
    if (!is_colon) return false;

    var i = colon_idx;
    while (i > 0) {
        i -= 1;
        const t = toks[i];
        if (t.type == .Comment) continue;
        if (t.type == .NewLine) return false;

        if (t.type == .Keyword and std.mem.eql(u8, t.data.sval.items, "for")) return true;

        if (t.type == .Symbol) {
            const c = t.data.cval;
            if (c == ';' or c == '{' or c == '}') return false;
        }
    }

    return false;
}

fn isPointerTypeStarContext(toks: []const token.Token, idx: usize, prev: token.Token, in_decl_only_ctx: bool) bool {
    var base_prev = prev;
    const prev_is_star = (prev.type == .Symbol and prev.data.cval == '*') or
        (prev.type == .Operator and std.mem.eql(u8, prev.data.sval.items, "*"));
    if (prev_is_star) {
        // For chains like `Type** name`, walk left to recover the base type token.
        var walk_idx = prev_significant_index(toks, idx) orelse return false;
        var walk_tok = toks[walk_idx];
        while ((walk_tok.type == .Symbol and walk_tok.data.cval == '*') or
            (walk_tok.type == .Operator and std.mem.eql(u8, walk_tok.data.sval.items, "*")))
        {
            walk_idx = prev_significant_index(toks, walk_idx) orelse return false;
            walk_tok = toks[walk_idx];
        }
        base_prev = walk_tok;
    }

    if (!in_decl_only_ctx and !isLikelyTypeToken(base_prev)) {
        const is_generic_close = (base_prev.type == .Operator and std.mem.eql(u8, base_prev.data.sval.items, ">")) or
            (base_prev.type == .Symbol and base_prev.data.cval == '>');
        if (!is_generic_close) return false;
    }

    var next_idx = nextSignificantIndex(toks, idx + 1) orelse return false;
    var next = toks[next_idx];

    // Support pointer chains such as `Type** name` by consuming subsequent stars.
    while ((next.type == .Symbol and next.data.cval == '*') or
        (next.type == .Operator and std.mem.eql(u8, next.data.sval.items, "*")))
    {
        next_idx = nextSignificantIndex(toks, next_idx + 1) orelse return false;
        next = toks[next_idx];
    }

    // Return type pointers: `...) Type* {` or `...) Type*;`
    if (next.type == .Symbol and (next.data.cval == '{' or next.data.cval == ';')) return true;

    // Generic argument pointer as the LAST type argument: `Vec<Type*>`
    // (closing `>`, no name follows the star).
    if (next.type == .Operator and std.mem.eql(u8, next.data.sval.items, ">")) return true;
    if (next.type == .Symbol and next.data.cval == '>') return true;

    // Generic argument pointer followed by ANOTHER type argument:
    // `Result<Type*, Error>`. A following `,` here would be ambiguous
    // with real multiplication followed by a call argument (`foo(a * b,
    // c)`) in general -- but `in_decl_only_ctx` already means we're
    // somewhere a value expression can't appear at all (a function's
    // return-type position, a field/param type, ...), so there's no
    // ambiguity to guard against. Without this, `Result<Expr *, Error>`
    // formatted with a stray space before the star and never converged
    // even under repeated `-fmt` passes (not idempotent).
    if (in_decl_only_ctx and next.type == .Operator and std.mem.eql(u8, next.data.sval.items, ",")) return true;

    // Unnamed pointer type immediately closing a parenthesized list, e.g. an
    // enum data-carrying variant's payload (`StatementFork(Node*)`) or a
    // function-type parameter (`fun(Node*) R`). Unambiguous: a real
    // multiplication can never be immediately followed by `)` (it always
    // needs a right operand first), so this can only be a bare pointer type.
    if (next.type == .Symbol and next.data.cval == ')') return true;

    // Declaration/field/param pointers: `Type* name` (name then delimiter)
    if (next.type == .Identifier) {
        const after_name_idx = nextSignificantIndex(toks, next_idx + 1) orelse return false;
        const after_name = toks[after_name_idx];
        if (after_name.type == .Symbol and (after_name.data.cval == ';' or after_name.data.cval == ',' or after_name.data.cval == ')' or after_name.data.cval == ']')) return true;
        if (after_name.type == .Operator and (std.mem.eql(u8, after_name.data.sval.items, "=") or std.mem.eql(u8, after_name.data.sval.items, ","))) return true;
    }
    return false;
}

fn appendAll(dst: *ArrayList(token.Token), src: []const token.Token) !void {
    for (src) |t| {
        try dst.append(t);
    }
}

const EmitState = struct {
    indent: *usize,
    at_line_start: *bool,
    prev_token: *?token.Token,
    out: *ArrayList(u8),
    allocator: mem.Allocator,
    /// True while emitting comment lines INSIDE a fenced code block (between ```
    /// markers in a doc comment). Inside a fence the comment body is preserved
    /// verbatim so code indentation survives; outside it is trimmed to one space
    /// after `//`. Persists across the import/global/rest emit passes.
    in_doc_fence: *bool,
};

const AsmRawRange = struct {
    start_idx: usize,
    end_idx: usize,
    start_pos: token.Pos,
    end_pos: token.Pos,
};

fn free_arg_list(allocator: mem.Allocator, args: []const []const u8) void {
    for (args) |a| allocator.free(a);
}

fn parse_command_line(allocator: mem.Allocator, text: []const u8) !ArrayList([]const u8) {
    var out = ArrayList([]const u8).init(allocator);
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
        if (i >= text.len) break;

        var buf = ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        const quote: ?u8 = if (text[i] == '"' or text[i] == '\'') blk: {
            const q = text[i];
            i += 1;
            break :blk q;
        } else null;

        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (quote != null) {
                if (c == quote.?) {
                    i += 1;
                    break;
                }
                if (c == '\\' and i + 1 < text.len) {
                    i += 1;
                    try buf.append(text[i]);
                    continue;
                }
                try buf.append(c);
            } else {
                if (std.ascii.isWhitespace(c)) break;
                try buf.append(c);
            }
        }

        const slice = try buf.toOwnedSlice();
        try out.append(slice);
    }
    return out;
}

fn replace_placeholders(allocator: mem.Allocator, text: []const u8, src: []const u8, out_path: []const u8) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i + 5 <= text.len and std.mem.eql(u8, text[i .. i + 5], "{src}")) {
            try buf.appendSlice(src);
            i += 4;
            continue;
        }
        if (i + 5 <= text.len and std.mem.eql(u8, text[i .. i + 5], "{out}")) {
            try buf.appendSlice(out_path);
            i += 4;
            continue;
        }
        try buf.append(text[i]);
    }

    return buf.toOwnedSlice();
}

const CompilerFlavor = enum {
    zig,
    cl,
    gcc_like,
    unknown,
};

fn detect_compiler_flavor(argv0: []const u8) CompilerFlavor {
    const base = std.fs.path.basename(argv0);
    if (std.mem.eql(u8, base, "zig") or std.mem.eql(u8, base, "zig.exe")) return .zig;
    if (std.mem.eql(u8, base, "cl") or std.mem.eql(u8, base, "cl.exe")) return .cl;
    if (std.mem.eql(u8, base, "gcc") or std.mem.eql(u8, base, "gcc.exe") or std.mem.eql(u8, base, "clang") or std.mem.eql(u8, base, "clang.exe") or std.mem.eql(u8, base, "cc")) return .gcc_like;
    return .unknown;
}

fn append_default_compile_args(allocator: mem.Allocator, argv_list: *ArrayList([]const u8), flavor: CompilerFlavor, c_path: []const u8, exe_file: []const u8, debug_info: bool) !void {
    switch (flavor) {
        .cl => {
            // C17 mode is required for compound-literal initializers and
            // mixed declarations/statements; /W0 silences warnings that
            // are noise for generated C.
            try argv_list.append(try allocator.dupe(u8, "/std:c17"));
            try argv_list.append(try allocator.dupe(u8, "/W0"));
            try argv_list.append(try allocator.dupe(u8, c_path));
            const out_flag = try std.fmt.allocPrint(allocator, "/Fe:{s}", .{exe_file});
            try argv_list.append(out_flag);
        },
        else => {
            // Use -g for DWARF symbols when debug info requested, -g0 otherwise (smaller binary).
            try argv_list.append(try allocator.dupe(u8, if (debug_info) "-g" else "-g0"));
            try argv_list.append(try allocator.dupe(u8, c_path));
            try argv_list.append(try allocator.dupe(u8, "-o"));
            try argv_list.append(try allocator.dupe(u8, exe_file));
            // GCC/Clang-style Unix threading support.
            if (builtin.target.os.tag != .windows) {
                try argv_list.append(try allocator.dupe(u8, "-pthread"));
            }
            // GCC/Clang-style Linux links libm separately.
            if (builtin.target.os.tag != .windows) {
                try argv_list.append(try allocator.dupe(u8, "-lm"));
            }
        },
    }
}

fn append_fun_cc_extra_args(
    allocator: mem.Allocator,
    argv_list: *ArrayList([]const u8),
    extra_items: []const []const u8,
    using_zig: bool,
    used_template: bool,
    non_template_base_argc: usize,
) !void {
    const skip_stale_zig_cc_arg = !using_zig and extra_items.len == 1 and std.mem.eql(u8, extra_items[0], "cc");
    if (skip_stale_zig_cc_arg) return;

    const extra_start_idx = argv_list.items.len;
    for (extra_items) |a| {
        try argv_list.append(try allocator.dupe(u8, a));
    }

    const zig_cc_env_style = using_zig and !used_template and extra_items.len >= 1 and std.mem.eql(u8, extra_items[0], "cc");
    if (zig_cc_env_style) {
        const cc_arg = argv_list.orderedRemove(extra_start_idx);
        try argv_list.insert(non_template_base_argc, cc_arg);
    }
}

const DefaultCompilerCandidate = struct {
    cmd: []const u8,
    flavor: CompilerFlavor,
    extra: []const []const u8,
};

fn get_default_compiler_candidates() []const DefaultCompilerCandidate {
    const windows = [_]DefaultCompilerCandidate{
        .{ .cmd = "zig", .flavor = .zig, .extra = &.{"cc"} },
        .{ .cmd = "clang", .flavor = .gcc_like, .extra = &.{} },
        .{ .cmd = "gcc", .flavor = .gcc_like, .extra = &.{} },
        .{ .cmd = "cl", .flavor = .cl, .extra = &.{"/nologo"} },
    };
    const unix = [_]DefaultCompilerCandidate{
        .{ .cmd = "zig", .flavor = .zig, .extra = &.{"cc"} },
        .{ .cmd = "clang", .flavor = .gcc_like, .extra = &.{} },
        .{ .cmd = "gcc", .flavor = .gcc_like, .extra = &.{} },
        .{ .cmd = "cc", .flavor = .gcc_like, .extra = &.{} },
    };
    return if (builtin.target.os.tag == .windows) windows[0..] else unix[0..];
}

pub fn default_compiler_hint() []const u8 {
    return switch (builtin.target.os.tag) {
        .windows => "zig cc, clang, gcc, cl",
        .macos => "zig cc, clang, gcc, cc",
        else => "zig cc, clang, gcc, cc",
    };
}

test "FUN_CC_ARGS stale cc is ignored for non-zig compilers" {
    const allocator = std.testing.allocator;
    var argv_list = ArrayList([]const u8).init(allocator);
    defer argv_list.deinit();
    defer free_arg_list(allocator, argv_list.items);

    try argv_list.append(try allocator.dupe(u8, "cl"));
    try argv_list.append(try allocator.dupe(u8, "/nologo"));
    try argv_list.append(try allocator.dupe(u8, "test.c"));
    try argv_list.append(try allocator.dupe(u8, "/Fetest.exe"));

    const before_len = argv_list.items.len;
    try append_fun_cc_extra_args(allocator, &argv_list, &.{"cc"}, false, true, 0);

    try std.testing.expectEqual(before_len, argv_list.items.len);
    for (argv_list.items) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "cc"));
    }
}

test "FUN_CC=zig with FUN_CC_ARGS=cc keeps zig cc ordering" {
    const allocator = std.testing.allocator;
    var argv_list = ArrayList([]const u8).init(allocator);
    defer argv_list.deinit();
    defer free_arg_list(allocator, argv_list.items);

    try argv_list.append(try allocator.dupe(u8, "zig"));
    try append_default_compile_args(allocator, &argv_list, .zig, "test.c", "test.exe", false);

    try append_fun_cc_extra_args(allocator, &argv_list, &.{"cc"}, true, false, 1);

    try std.testing.expect(argv_list.items.len >= 2);
    try std.testing.expect(std.mem.eql(u8, argv_list.items[0], "zig"));
    try std.testing.expect(std.mem.eql(u8, argv_list.items[1], "cc"));
    try std.testing.expect(!std.mem.eql(u8, argv_list.items[argv_list.items.len - 1], "cc"));
}

test "default gcc-like args include pthread on non-windows" {
    if (builtin.target.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    var argv_list = ArrayList([]const u8).init(allocator);
    defer argv_list.deinit();
    defer free_arg_list(allocator, argv_list.items);

    try argv_list.append(try allocator.dupe(u8, "clang"));
    try append_default_compile_args(allocator, &argv_list, .gcc_like, "test.c", "test.exe", false);

    var has_pthread = false;
    for (argv_list.items) |arg| {
        if (std.mem.eql(u8, arg, "-pthread")) {
            has_pthread = true;
            break;
        }
    }
    try std.testing.expect(has_pthread);
}

test "default cl args do not include pthread" {
    const allocator = std.testing.allocator;
    var argv_list = ArrayList([]const u8).init(allocator);
    defer argv_list.deinit();
    defer free_arg_list(allocator, argv_list.items);

    try argv_list.append(try allocator.dupe(u8, "cl"));
    try append_default_compile_args(allocator, &argv_list, .cl, "test.c", "test.exe", false);

    for (argv_list.items) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "-pthread"));
    }
}

fn prev_significant_index(toks: []const token.Token, idx: usize) ?usize {
    if (idx == 0) return null;
    var i: isize = @as(isize, @intCast(idx)) - 1;
    while (i >= 0) : (i -= 1) {
        const t = toks[@intCast(i)];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return @intCast(i);
    }
    return null;
}

fn next_significant_index(toks: []const token.Token, idx: usize) ?usize {
    var i: usize = idx + 1;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return i;
    }
    return null;
}

fn has_paren_before_brace(toks: []const token.Token, idx: usize) bool {
    if (idx == 0) return false;
    var i: isize = @as(isize, @intCast(idx)) - 1;
    // Scanning back from a `{`, a generic return type like `Map<K, V>` sits between
    // the param-list `)` and the `{`. Its INTERNAL comma (`<K, V>`) must NOT be treated
    // as a statement/argument separator that aborts the scan — otherwise a method whose
    // return type has multiple type args is mis-detected as a non-block brace. Track
    // angle depth (seen right-to-left: `>` opens, `<` closes) and ignore commas inside.
    var angle_depth: usize = 0;
    while (i >= 0) : (i -= 1) {
        const t = toks[@intCast(i)];
        if (t.type == .NewLine or t.type == .Comment) continue;

        const is_gt = (t.type == .Operator and is_all_gt(t.data.sval.items)) or (t.type == .Symbol and t.data.cval == '>');
        const is_lt = (t.type == .Operator and std.mem.eql(u8, t.data.sval.items, "<")) or (t.type == .Symbol and t.data.cval == '<');
        if (is_gt) {
            // A `>>`/`>>>` token closes multiple nested generics at once.
            angle_depth += if (t.type == .Operator) t.data.sval.items.len else 1;
            continue;
        }
        if (is_lt and angle_depth > 0) {
            angle_depth -= 1;
            continue;
        }
        if (angle_depth > 0) continue; // inside a generic arg list: ignore commas etc.

        if (t.type == .Symbol) {
            const c = t.data.cval;
            if (c == ')') return true;
            if (c == '{' or c == '}' or c == ';' or c == ',') return false;
        }
        if (t.type == .Operator) {
            const op = t.data.sval.items;
            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, ",") or std.mem.eql(u8, op, ":")) return false;
        }
    }
    return false;
}

/// True when `s` is a run of one or more `>` (a `>`, `>>`, or `>>>` operator token,
/// which the lexer emits for stacked generic closes like `Vec<Map<K, V>>`).
fn is_all_gt(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c != '>') return false;
    }
    return true;
}

fn generic_angle_sequence_followed_by_lbrace(toks: []const token.Token, open_idx: usize, first_arg_idx: usize) bool {
    _ = open_idx;
    var depth: usize = 1;
    var i: usize = first_arg_idx + 1;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.type == .NewLine or t.type == .Comment) continue;

        const is_lt = (t.type == .Operator and std.mem.eql(u8, t.data.sval.items, "<")) or
            (t.type == .Symbol and t.data.cval == '<');
        if (is_lt) {
            depth += 1;
            continue;
        }

        const closes = generic_close_count(t);
        if (closes == 0) continue;
        if (closes >= depth) {
            const after_idx = next_significant_index(toks, i) orelse return false;
            const after = toks[after_idx];
            return (after.type == .Symbol and after.data.cval == '{') or
                (after.type == .Operator and std.mem.eql(u8, after.data.sval.items, "{"));
        }
        depth -= closes;
    }
    return false;
}

fn is_generic_angle_open(toks: []const token.Token, idx: usize, in_decl_only_ctx: bool) bool {
    if (idx >= toks.len) return false;
    const t = toks[idx];
    const is_lt = (t.type == .Operator and std.mem.eql(u8, t.data.sval.items, "<")) or
        (t.type == .Symbol and t.data.cval == '<');
    if (!is_lt) return false;

    const prev_idx = prev_significant_index(toks, idx) orelse return false;
    const next_idx = next_significant_index(toks, idx) orelse return false;
    const prev = toks[prev_idx];
    const next = toks[next_idx];

    if (!isLikelyTypeToken(prev)) {
        if (!(in_decl_only_ctx and prev.type == .Identifier)) return false;
    }
    if (!isLikelyTypeToken(next)) return false;

    if (in_decl_only_ctx) return true;

    const before_prev_idx = prev_significant_index(toks, prev_idx);
    if (before_prev_idx == null) return true;
    const before_prev = toks[before_prev_idx.?];
    if (before_prev.type == .Keyword) {
        const kw = before_prev.data.sval.items;
        // `as` covers a generic quirk binding in an impl header: `impl T as Iterator<U>`.
        if (std.mem.eql(u8, kw, "impl") or std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "fun") or std.mem.eql(u8, kw, "pub") or std.mem.eql(u8, kw, "enum") or std.mem.eql(u8, kw, "quirk") or std.mem.eql(u8, kw, "as")) return true;
        if (std.mem.eql(u8, kw, "ret") and generic_angle_sequence_followed_by_lbrace(toks, idx, next_idx)) return true;
    }
    if (before_prev.type == .Symbol) {
        const c = before_prev.data.cval;
        if (c == '{' or c == '}' or c == ';' or c == ',' or c == '(' or c == ')') return true;
    }
    if (before_prev.type == .Operator) {
        const op = before_prev.data.sval.items;
        if (std.mem.eql(u8, op, "(") or std.mem.eql(u8, op, "[") or std.mem.eql(u8, op, ",") or std.mem.eql(u8, op, ":")) return true;
        if (std.mem.eql(u8, op, "=") and generic_angle_sequence_followed_by_lbrace(toks, idx, next_idx)) return true;
    }
    return false;
}

fn generic_close_count(t: token.Token) usize {
    if (t.type == .Symbol and t.data.cval == '>') return 1;
    if (t.type != .Operator) return 0;
    const op = t.data.sval.items;
    if (op.len == 0) return 0;
    for (op) |ch| {
        if (ch != '>') return 0;
    }
    return op.len;
}

fn find_asm_body_block(toks: []const token.Token, asm_idx: usize) ?AsmRawRange {
    var paren_depth: isize = 0;
    var i: usize = asm_idx + 1;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.type == .NewLine or t.type == .Comment) continue;

        if (t.type == .Operator and std.mem.eql(u8, t.data.sval.items, "(")) {
            paren_depth += 1;
            continue;
        }
        if (t.type == .Symbol and t.data.cval == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            continue;
        }

        if (paren_depth == 0) {
            if (t.type == .String) return null;
            if (t.type == .Symbol and t.data.cval == '{') {
                var depth: isize = 1;
                var j: usize = i + 1;
                while (j < toks.len) : (j += 1) {
                    const tj = toks[j];
                    if (tj.type == .NewLine or tj.type == .Comment) continue;
                    if (tj.type == .Symbol and tj.data.cval == '{') depth += 1;
                    if (tj.type == .Symbol and tj.data.cval == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            return .{ .start_idx = i, .end_idx = j, .start_pos = t.pos, .end_pos = tj.pos };
                        }
                    }
                }
                return null;
            }
        }
    }
    return null;
}

fn pos_to_index(line_starts: []const usize, pos: token.Pos, use_end: bool) usize {
    const line = if (use_end and pos.end_line != 0) pos.end_line else pos.line;
    const col = if (use_end and pos.end_line != 0) pos.end_col else pos.start_col;
    if (line == 0) return 0;
    const li: usize = @as(usize, @intCast(line - 1));
    if (li >= line_starts.len) return line_starts[line_starts.len - 1];
    const base = line_starts[li];
    if (col == 0) return base;
    return base + @as(usize, col - 1);
}

const fmt_indent_width: usize = 2;

/// Maximum rendered line width before the formatter wraps a comma-separated group
/// (call args, function params, compound-init fields, array literals) one item per
/// line. Lines that fit stay on one line.
const fmt_max_line_width: usize = 100;

/// True if `t` opens a wrappable comma group: `(` (call/params), `[` (array literal).
/// A `{` compound-init open is detected separately (it needs the preceding token to
/// be a type/`>`, not a block).
fn isWrapOpenParenOrBracket(t: token.Token) bool {
    return t.type == .Operator and (std.mem.eql(u8, t.data.sval.items, "(") or std.mem.eql(u8, t.data.sval.items, "["));
}

fn matchingCloseChar(open: token.Token) u8 {
    if (open.type == .Operator) {
        if (std.mem.eql(u8, open.data.sval.items, "(")) return ')';
        if (std.mem.eql(u8, open.data.sval.items, "[")) return ']';
    }
    if (open.type == .Symbol and open.data.cval == '{') return '}';
    return 0;
}

const WrapGroup = struct {
    /// Index of the matching close token.
    close_idx: usize,
    /// Single-line rendered width of the whole group, open..close inclusive.
    width: usize,
    /// True if the group contains at least one top-level comma (worth wrapping).
    has_comma: bool,
};

/// Measure the single-line rendered width of the bracket group that opens at
/// `open_idx`, and locate its matching close. Width counts each significant token's
/// rendered text plus the one space the formatter would put after a top-level comma
/// (`, `). Comments/newlines inside are ignored for the measurement. Nested brackets
/// are spanned but their inner commas don't count as top-level. Returns null if the
/// group is unterminated. Conservative: this is only a heuristic to DECIDE wrapping;
/// it never has to be byte-exact, only good enough to pick lines clearly over budget.
fn measureWrapGroup(
    allocator: mem.Allocator,
    toks: []const token.Token,
    open_idx: usize,
    source: []const u8,
    line_starts: []const usize,
) !?WrapGroup {
    const open = toks[open_idx];
    const close_c = matchingCloseChar(open);
    if (close_c == 0) return null;

    var depth: isize = 0;
    var width: usize = 0;
    var has_comma = false;
    var i: usize = open_idx;
    var prev_was_value: bool = false; // for deciding inter-token spacing roughly
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.type == .NewLine or t.type == .Comment) continue;

        // Track nesting to find the matching close and top-level commas.
        if (t.type == .Operator and (std.mem.eql(u8, t.data.sval.items, "(") or std.mem.eql(u8, t.data.sval.items, "["))) {
            depth += 1;
        } else if (t.type == .Symbol and t.data.cval == '{') {
            depth += 1;
        } else if (t.type == .Symbol and (t.data.cval == ')' or t.data.cval == ']' or t.data.cval == '}')) {
            depth -= 1;
        }

        const s = try token_text(allocator, t, source, line_starts);
        defer allocator.free(s);

        // Approximate spacing: a leading space before an identifier/keyword/number
        // that follows another value token, and after a comma. Good enough for a
        // width threshold decision.
        const is_value = t.type == .Identifier or t.type == .Keyword or t.type == .Number or t.type == .String or t.type == .Boolean;
        if (is_value and prev_was_value) width += 1;
        width += s.len;
        prev_was_value = is_value;

        if (t.type == .Operator and std.mem.eql(u8, t.data.sval.items, ",") and depth == 1) {
            has_comma = true;
            width += 1; // the space after `, `
        }
        if (depth == 0 and i > open_idx) {
            return WrapGroup{ .close_idx = i, .width = width, .has_comma = has_comma };
        }
    }
    return null;
}

/// Current column = number of characters since the last newline in `out`.
fn currentColumn(out: *const ArrayList(u8)) usize {
    var n = out.items.len;
    var col: usize = 0;
    while (n > 0) {
        n -= 1;
        if (out.items[n] == '\n') break;
        col += 1;
    }
    return col;
}

/// A `fit` arm body `{ ... }` is eligible to stay on ONE line when it holds a
/// single simple statement: no nested `{}`/blocks, no comments, no inner `;` except
/// a single trailing one, and short enough to fit the width budget. `open_idx` is
/// the `{` token. Returns the matching `}` index when eligible (so the caller emits
/// it inline and jumps past it), else null. Keeps short pattern-match arms compact:
///   `Option.Some(v) -> { ret v; }`  instead of exploding to three lines.
fn fitArmInlineClose(toks: []const token.Token, open_idx: usize, source: []const u8, line_starts: []const usize, allocator: mem.Allocator, start_col: usize) ?usize {
    var depth: usize = 0;
    var i = open_idx;
    var semis: usize = 0;
    var width: usize = start_col + 2; // "{ "
    var close_idx: ?usize = null;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.type == .Comment) return null; // comments force multi-line
        if (t.type == .NewLine) continue;
        if (t.type == .Symbol and t.data.cval == '{') {
            depth += 1;
            if (depth > 1) return null; // nested block -> multi-line
            continue;
        }
        if (t.type == .Symbol and t.data.cval == '}') {
            depth -= 1;
            if (depth == 0) {
                close_idx = i;
                break;
            }
            continue;
        }
        // A `;` at the arm-body's top level: allow at most one (single statement).
        if (t.type == .Symbol and t.data.cval == ';' and depth == 1) {
            semis += 1;
            if (semis > 1) return null;
            continue;
        }
        const s = token_text(allocator, t, source, line_starts) catch return null;
        defer allocator.free(s);
        width += s.len + 1; // approximate: token + a separating space
        if (width > fmt_max_line_width) return null;
    }
    const ci = close_idx orelse return null;
    return ci;
}

/// Find the byte index of a line's trailing-comment `//`, or null if the line has
/// none (no `//`, or a `//` that is a standalone comment with no code before it, or
/// a `//` that sits inside a string/char literal). `line` excludes the newline.
fn trailingCommentStart(line: []const u8) ?usize {
    var in_str = false;
    var in_chr = false;
    // A backtick raw string keeps its body verbatim, `//` included, so a
    // `//` inside one is not a comment. An unterminated raw string runs to
    // the end of the line, which is exactly how a multi-line raw string's
    // continuation lines read.
    var in_raw = false;
    var i: usize = 0;
    var first_code: ?usize = null; // first non-space code column
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_raw) {
            if (c == '`') in_raw = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') in_str = false;
            continue;
        }
        if (in_chr) {
            if (c == '\\') {
                i += 1;
            } else if (c == '\'') in_chr = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            if (first_code == null) first_code = i;
            continue;
        }
        if (c == '\'') {
            in_chr = true;
            if (first_code == null) first_code = i;
            continue;
        }
        if (c == '`') {
            in_raw = true;
            if (first_code == null) first_code = i;
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            // A trailing comment must have code before it on the line.
            if (first_code != null and first_code.? < i) return i;
            return null;
        }
        if (c != ' ' and c != '\t') {
            if (first_code == null) first_code = i;
        }
    }
    return null;
}

/// Width (in columns) of the code portion of a line that ends at the trailing
/// comment starting at `cstart` — i.e. the code with trailing spaces trimmed.
fn codeWidthBeforeComment(line: []const u8, cstart: usize) usize {
    var n = cstart;
    while (n > 0 and (line[n - 1] == ' ' or line[n - 1] == '\t')) n -= 1;
    return n;
}

/// Align consecutive trailing comments to a common column (gofmt-style). A run is a
/// maximal block of adjacent lines that each carry a trailing comment AND share the
/// same leading indentation; within a run, every `//` is padded to one space past
/// the widest code portion. Standalone comment lines, blank lines, and comment-less
/// code lines break a run. Operates on the finished output buffer in place; it only
/// adjusts the spaces between code and `//`, so it is idempotent.
fn alignTrailingComments(allocator: mem.Allocator, out: *ArrayList(u8)) !void {
    // Split into lines (without the trailing newline of each).
    var lines = ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    {
        var start: usize = 0;
        var i: usize = 0;
        while (i < out.items.len) : (i += 1) {
            if (out.items[i] == '\n') {
                try lines.append(out.items[start..i]);
                start = i + 1;
            }
        }
        if (start < out.items.len) try lines.append(out.items[start..]);
    }

    // Precompute, per line, the trailing-comment start (or null) and indent width.
    const Info = struct { cstart: ?usize, indent: usize, code_w: usize };
    var infos = ArrayList(Info).init(allocator);
    defer infos.deinit();
    for (lines.items) |ln| {
        var indent: usize = 0;
        while (indent < ln.len and (ln[indent] == ' ' or ln[indent] == '\t')) indent += 1;
        const cstart = trailingCommentStart(ln);
        const cw = if (cstart) |cs| codeWidthBeforeComment(ln, cs) else 0;
        try infos.append(.{ .cstart = cstart, .indent = indent, .code_w = cw });
    }

    var result = ArrayList(u8).init(allocator);
    defer result.deinit();

    var li: usize = 0;
    while (li < lines.items.len) {
        if (infos.items[li].cstart == null) {
            try result.appendSlice(lines.items[li]);
            try result.append('\n');
            li += 1;
            continue;
        }
        // Start of a run: gather consecutive comment lines with the same indent.
        const run_indent = infos.items[li].indent;
        var run_end = li;
        var target: usize = 0;
        while (run_end < lines.items.len and infos.items[run_end].cstart != null and infos.items[run_end].indent == run_indent) {
            if (infos.items[run_end].code_w > target) target = infos.items[run_end].code_w;
            run_end += 1;
        }
        // Emit each line in the run with its comment padded to `target + 1`.
        var k = li;
        while (k < run_end) : (k += 1) {
            const ln = lines.items[k];
            const cs = infos.items[k].cstart.?;
            const code = ln[0..codeWidthBeforeComment(ln, cs)];
            try result.appendSlice(code);
            // At least one space between code and comment; pad to the target column.
            const pad = (target - code.len) + 1;
            try result.appendNTimes(' ', pad);
            try result.appendSlice(ln[cs..]);
            try result.append('\n');
        }
        li = run_end;
    }

    // Replace out with result (drop any extra trailing newline beyond the original;
    // the caller normalizes the final newline).
    out.clearRetainingCapacity();
    try out.appendSlice(result.items);
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        out.items.len -= 1; // caller re-adds exactly one
    }
}

fn ensureBlankLine(out: *ArrayList(u8)) !void {
    // Ensure output ends with at least two '\n' characters.
    const n = out.items.len;
    if (n >= 2 and out.items[n - 1] == '\n' and out.items[n - 2] == '\n') return;
    if (n >= 1 and out.items[n - 1] == '\n') {
        try out.append('\n');
        return;
    }
    try out.append('\n');
    try out.append('\n');
}

fn is_top_level_construct_keyword(kw: []const u8) bool {
    return std.mem.eql(u8, kw, "fun") or
        std.mem.eql(u8, kw, "compound") or
        std.mem.eql(u8, kw, "quirk") or
        std.mem.eql(u8, kw, "enum") or
        std.mem.eql(u8, kw, "impl") or
        std.mem.eql(u8, kw, "test");
}

fn emitTokens(state: *EmitState, toks: []const token.Token, source: []const u8, line_starts: []const usize) !void {
    var idx: usize = 0;
    var pending_newlines: usize = 0;
    var cond_paren_depth: usize = 0;
    var skipping_cond_outer_parens: bool = false;
    var wrap_cond_open_at: ?usize = null;
    var wrap_cond_close_before: ?usize = null;
    var prev_unary_prefix: bool = false;
    var in_fun_signature: bool = false;
    // A `test "name" { ... }` block's body is ordinary executable statement
    // code, exactly like a `fun`'s body -- NOT a declaration block like
    // compound/quirk/impl (which `test` used to be grouped with for
    // `pending_decl_block_open`). Tracked the same way `in_fun_signature`
    // is, so the block's `{` sets `function_body_depth` directly instead
    // of `decl_block_depth`. See `in_decl_only_ctx`'s own use of these two
    // depths for why this distinction matters: getting it wrong made every
    // statement inside a `test` block get formatted as if it were a
    // declaration-context type annotation (e.g. `*p = f();` mangled to
    // `* p =f();`, confirmed directly).
    var in_test_signature: bool = false;
    var pending_decl_block_open: bool = false;
    var decl_block_depth: isize = 0;
    var pending_enum_block_open: bool = false;
    var enum_block_depth: isize = 0;
    // Paren nesting INSIDE an enum body, used to tell a top-level variant separator
    // comma (`A, B`) — which becomes a newline — from a comma inside a data-carrying
    // variant's payload (`Pair(num, num)`), which must stay `, ` on the same line.
    var enum_payload_paren_depth: isize = 0;
    var pending_control_block_open: bool = false;
    var function_body_depth: isize = 0;
    var generic_angle_depth: usize = 0;
    var asm_raw: ?AsmRawRange = null;
    // What an opening `{` actually incremented, so the matching `}` decrements
    // EXACTLY that counter back -- not a blind "decrement everything that's
    // nonzero" (see the bug this fixes: a bare impl method's body closing was
    // ALSO decrementing `decl_block_depth`, the ENCLOSING `impl`/`compound`
    // block's own counter, one step too many. After the first such method in
    // an `impl` block, `decl_block_depth` prematurely hit 0, so every method
    // after it lost `in_decl_only_ctx` for its own signature -- e.g. a
    // generic argument's pointer star, or its final closing `>`, silently
    // reverted to non-declaration spacing).
    const BraceKind = enum { not_a_block, plain_block, decl_block, enum_block, function_body };
    var brace_stack = ArrayList(BraceKind).init(state.allocator);
    defer brace_stack.deinit();
    // Stack of close-token indices for comma groups currently being wrapped one
    // item per line (width-based wrapping). When the current token's index matches
    // the top entry, we emit the closing delimiter on its own dedented line.
    var wrap_close_stack = ArrayList(usize).init(state.allocator);
    defer wrap_close_stack.deinit();
    // When set, we are emitting a short `fit` arm body inline on one line; this is
    // the index of its closing `}`. Until then, `;`/`,` inside emit a space rather
    // than a newline, keeping `Option.Some(v) -> { ret v; }` on one line. Reset
    // when we emit that close brace.
    var inline_arm_close: ?usize = null;
    // Running nesting depth of `(`/`[`/`{` as the emit loop sees them, used to tell
    // a wrap group's OWN top-level commas from commas in nested groups.
    var bracket_depth: isize = 0;
    // For each active wrap group, the bracket_depth at which its items live (its
    // commas fire a line break only at exactly this depth). Parallel to
    // wrap_close_stack.
    var wrap_item_depth = ArrayList(isize).init(state.allocator);
    defer wrap_item_depth.deinit();
    while (idx < toks.len) : (idx += 1) {
        const t2 = toks[idx];
        if (t2.type == .NewLine) {
            // A newline written inside an open generic argument list (e.g. a
            // parameter type like `Map<str,\nGlobalSymbolInfo>`) splits a type
            // expression that should read as one atomic unit; collapse it away
            // so the normal spacing rule between tokens applies instead.
            if (generic_angle_depth == 0) {
                pending_newlines += 1;
            }
            continue;
        }

        // How many source newlines preceded this token. Captured before the reset
        // below so a `.Comment` can tell a trailing/inline comment (`x; // note`,
        // newlines_before == 0) from a standalone comment line (>= 1).
        const newlines_before = pending_newlines;

        // Preserve blank lines (2+ newlines) between statements/constructs.
        if (pending_newlines >= 2) {
            if (!state.at_line_start.*) try state.out.append('\n');
            try ensureBlankLine(state.out);
            state.at_line_start.* = true;
            state.prev_token.* = null;
        }
        pending_newlines = 0;

        // Track paren nesting inside an enum body so a payload comma (`Pair(num,
        // num)`) is not mistaken for a variant separator. Counted before the token
        // is emitted; a `)` decrements after the check below uses the open depth.
        if (enum_block_depth > 0) {
            if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "(")) {
                enum_payload_paren_depth += 1;
            } else if (t2.type == .Symbol and t2.data.cval == ')') {
                if (enum_payload_paren_depth > 0) enum_payload_paren_depth -= 1;
            }
        }

        // Maintain a general bracket-nesting depth for width-based comma wrapping.
        // Opens increment BEFORE the token is emitted (so a wrap group's own items
        // sit at the open's depth+1); closes decrement here so the close token is
        // seen at the group's outer depth. `bracket_depth` is otherwise inert.
        const tok_is_open = (t2.type == .Operator and (std.mem.eql(u8, t2.data.sval.items, "(") or std.mem.eql(u8, t2.data.sval.items, "["))) or (t2.type == .Symbol and t2.data.cval == '{');
        const tok_is_close = t2.type == .Symbol and (t2.data.cval == ')' or t2.data.cval == ']' or t2.data.cval == '}');
        if (tok_is_open) {
            bracket_depth += 1;
        } else if (tok_is_close) {
            bracket_depth -= 1;
        }

        // Close of an active wrap group: emit the closing delimiter on its own
        // dedented line. A trailing comma was already turned into `,\n<indent>`
        // by the comma handler, so the last item sits one line above the close.
        if (tok_is_close and wrap_close_stack.items.len > 0 and idx == wrap_close_stack.items[wrap_close_stack.items.len - 1]) {
            _ = wrap_close_stack.pop();
            _ = wrap_item_depth.pop();
            if (state.indent.* > 0) state.indent.* -= 1;
            // Strip a trailing run of spaces left by the last item's break, then
            // ensure we're at line start at the dedented indent.
            var n = state.out.items.len;
            while (n > 0 and (state.out.items[n - 1] == ' ' or state.out.items[n - 1] == '\t')) n -= 1;
            state.out.items.len = n;
            if (!(n > 0 and state.out.items[n - 1] == '\n')) try state.out.append('\n');
            try state.out.appendNTimes(' ', state.indent.* * fmt_indent_width);
            try state.out.append(t2.data.cval);
            state.at_line_start.* = false;
            state.prev_token.* = t2;
            continue;
        }

        if (asm_raw) |range| {
            if (idx == range.start_idx) {
                const start = pos_to_index(line_starts, range.start_pos, false);
                const end_excl = pos_to_index(line_starts, range.end_pos, true);
                if (start <= end_excl and end_excl <= source.len) {
                    try state.out.appendSlice(source[start..end_excl]);
                    if (end_excl > start and source[end_excl - 1] == '\n') {
                        state.at_line_start.* = true;
                    } else {
                        state.at_line_start.* = false;
                    }
                }
                state.prev_token.* = null;
                asm_raw = null;
                idx = range.end_idx;
                continue;
            }
        }

        // Strip outer parentheses in conditions: `if (cond)` -> `if cond`.
        // Preserve inner parentheses to keep grouping.
        // Implementation note: only skip the outermost pair; emit all inner tokens via the
        // normal formatting path so spacing rules still apply (notably `if (`).
        if (skipping_cond_outer_parens) {
            if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "(")) {
                if (cond_paren_depth == 0) {
                    cond_paren_depth = 1;
                    continue; // skip outer `(`
                }
                cond_paren_depth += 1; // inner `(`
            }
            if (t2.type == .Symbol and t2.data.cval == ')') {
                if (cond_paren_depth == 1) {
                    cond_paren_depth = 0;
                    skipping_cond_outer_parens = false;
                    continue; // skip outer `)`
                }
                if (cond_paren_depth > 1) {
                    cond_paren_depth -= 1; // inner `)`
                }
            }
        }

        // For single-statement `if/elif` (no `{}`), keep/add parentheses around the condition
        // to disambiguate where the condition ends.
        // Example: `if w < 0 w = -w;` must become `if (w < 0) w = -w;`.
        if (wrap_cond_open_at) |open_at| {
            if (idx == open_at) {
                const last2 = if (state.out.items.len > 0) state.out.items[state.out.items.len - 1] else 0;
                if (last2 != ' ' and last2 != '\n' and last2 != '\t') try state.out.append(' ');
                try state.out.append('(');
                // Prevent the normal spacing rules from inserting a space after `(`.
                state.prev_token.* = null;
                wrap_cond_open_at = null;
            }
        }
        if (wrap_cond_close_before) |close_before| {
            if (idx == close_before) {
                try state.out.append(')');
                try state.out.append(' ');
                state.prev_token.* = null;
                wrap_cond_close_before = null;
            }
        }

        if (t2.type == .Comment) {
            const s2 = try token_text(state.allocator, t2, source, line_starts);
            defer state.allocator.free(s2);

            // A trailing/inline comment (`Foo, // note`) stays on the same line as
            // the code it follows: no source newline separated them. Note that a
            // preceding separator handler (enum variant `,`, statement `;`) may have
            // ALREADY emitted a `\n` (+ indent), leaving us at line start — so when
            // there was no source newline we retract that trailing whitespace run
            // back to the code, then append `<space>// note` inline.
            if (newlines_before == 0) {
                var n = state.out.items.len;
                while (n > 0 and (state.out.items[n - 1] == ' ' or state.out.items[n - 1] == '\t')) n -= 1;
                if (n > 0 and state.out.items[n - 1] == '\n') {
                    n -= 1; // drop the single separator newline we just emitted
                    state.out.items.len = n;
                }
                const last_ch = if (state.out.items.len > 0) state.out.items[state.out.items.len - 1] else 0;
                if (last_ch != 0 and last_ch != ' ' and last_ch != '\t' and last_ch != '\n') try state.out.append(' ');
                try state.out.appendSlice(s2);
                try state.out.append('\n');
                state.at_line_start.* = true;
                state.prev_token.* = null;
                continue;
            }

            // Standalone comment line: own line at the current indent.
            if (!state.at_line_start.*) {
                try state.out.append('\n');
                state.at_line_start.* = true;
            }
            if (state.at_line_start.*) {
                try state.out.appendNTimes(' ', state.indent.* * fmt_indent_width);
            }

            // Fenced code blocks in doc comments: a ``` line opens/closes a fence.
            // INSIDE a fence the body is preserved VERBATIM (after the `// ` prefix)
            // so code indentation survives instead of being flattened to one space.
            // Outside, the body is trimmed to exactly one space after `//`.
            const raw_body = t2.data.sval.items;
            const trimmed_body = std.mem.trim(u8, raw_body, " \t");
            const is_fence_marker = std.mem.startsWith(u8, trimmed_body, "```");

            if (state.in_doc_fence.*) {
                // Preserve the body VERBATIM after `//` (including the leading-space
                // run that encodes code indentation). Emitting `//` + raw_body — with
                // no extra inserted space and no trimming — keeps re-runs idempotent.
                try state.out.appendSlice("//");
                try state.out.appendSlice(raw_body);
                if (is_fence_marker) state.in_doc_fence.* = false; // closing fence
            } else {
                try state.out.appendSlice(s2);
                if (is_fence_marker) state.in_doc_fence.* = true; // opening fence
            }

            try state.out.append('\n');
            state.at_line_start.* = true;
            state.prev_token.* = null;
            continue;
        }

        if (t2.type == .Keyword) {
            const kw2 = t2.data.sval.items;
            if (std.mem.eql(u8, kw2, "asm")) {
                asm_raw = find_asm_body_block(toks, idx);
            }
            if (std.mem.eql(u8, kw2, "fun")) {
                in_fun_signature = true;
            }
            if (std.mem.eql(u8, kw2, "test")) {
                in_test_signature = true;
            }
            if (std.mem.eql(u8, kw2, "compound") or std.mem.eql(u8, kw2, "quirk") or std.mem.eql(u8, kw2, "impl")) {
                pending_decl_block_open = true;
            }
            if (std.mem.eql(u8, kw2, "enum")) {
                pending_enum_block_open = true;
            }
            if (std.mem.eql(u8, kw2, "if") or std.mem.eql(u8, kw2, "elif")) {
                // Decide whether this `if/elif` is a block (`{}`) or a single-statement form.
                // If it's a block and the condition is parenthesized, we strip the outer parens.
                // If it's single-statement and the condition is NOT parenthesized, we add parens.
                pending_control_block_open = false;
                var jcond: usize = idx + 1;
                while (jcond < toks.len and (toks[jcond].type == .NewLine or toks[jcond].type == .Comment)) : (jcond += 1) {}
                if (jcond < toks.len) {
                    const cond_has_parens = toks[jcond].type == .Operator and std.mem.eql(u8, toks[jcond].data.sval.items, "(");

                    // A leading `(` only wraps the WHOLE condition (safe to
                    // strip, `if (a) {` -> `if a {`) when its MATCHING `)` is
                    // immediately followed by `{`. If more operators follow
                    // the `)` (`if (status & 127) == 0 {`), the parens only
                    // group a SUB-expression -- stripping them would silently
                    // change the parsed expression tree (Fun, like C, binds
                    // `==` tighter than `&`/`|`/`^`, so `status & 127 == 0`
                    // means `status & (127 == 0)`, not `(status & 127) == 0`).
                    var parens_wrap_whole_cond = false;
                    if (cond_has_parens) {
                        var pdepth: isize = 1;
                        var k = jcond + 1;
                        while (k < toks.len and pdepth > 0) : (k += 1) {
                            const tk = toks[k];
                            if (tk.type == .Operator and std.mem.eql(u8, tk.data.sval.items, "(")) pdepth += 1;
                            if (tk.type == .Symbol and tk.data.cval == ')') pdepth -= 1;
                        }
                        var k2 = k;
                        while (k2 < toks.len and (toks[k2].type == .NewLine or toks[k2].type == .Comment)) : (k2 += 1) {}
                        if (k2 < toks.len and toks[k2].type == .Symbol and toks[k2].data.cval == '{') {
                            parens_wrap_whole_cond = true;
                        }
                    }

                    // Scan forward to determine if this `if` uses a `{` block before the next `;`.
                    var depth_paren: isize = 0;
                    var depth_bracket: isize = 0;
                    var is_block: bool = false;
                    var is_single_stmt: bool = false;
                    var jscan: usize = jcond;
                    while (jscan < toks.len) : (jscan += 1) {
                        const tj = toks[jscan];
                        if (tj.type == .NewLine or tj.type == .Comment) continue;
                        if (tj.type == .Operator and std.mem.eql(u8, tj.data.sval.items, "(")) depth_paren += 1;
                        if (tj.type == .Symbol and tj.data.cval == ')') {
                            if (depth_paren > 0) depth_paren -= 1;
                        }
                        if (tj.type == .Operator and std.mem.eql(u8, tj.data.sval.items, "[")) depth_bracket += 1;
                        if (tj.type == .Symbol and tj.data.cval == ']') {
                            if (depth_bracket > 0) depth_bracket -= 1;
                        }

                        if (depth_paren == 0 and depth_bracket == 0 and tj.type == .Symbol) {
                            if (tj.data.cval == '{') {
                                is_block = true;
                                break;
                            }
                            if (tj.data.cval == ';') {
                                is_single_stmt = true;
                                break;
                            }
                        }
                    }

                    if (is_block and parens_wrap_whole_cond) {
                        skipping_cond_outer_parens = true;
                        cond_paren_depth = 0;
                        pending_control_block_open = true;
                    } else if (is_block) {
                        pending_control_block_open = true;
                    } else if (is_single_stmt and !cond_has_parens) {
                        // Find a reasonable statement start boundary so we can wrap only the condition.
                        const stmt_keywords = [_][]const u8{ "ret", "break", "continue", "fit", "for", "if" };
                        const assign_ops = [_][]const u8{ "=", "+=", "-=", "*=", "/=", "++", "--" };

                        var stmt_start: ?usize = null;
                        var depthp: isize = 0;
                        var depthb: isize = 0;
                        var prev_sig_at_depth0: ?usize = null;
                        var jfind: usize = jcond;
                        while (jfind < toks.len) : (jfind += 1) {
                            const tj = toks[jfind];
                            if (tj.type == .NewLine or tj.type == .Comment) continue;

                            if (tj.type == .Operator and std.mem.eql(u8, tj.data.sval.items, "(")) depthp += 1;
                            if (tj.type == .Symbol and tj.data.cval == ')') {
                                if (depthp > 0) depthp -= 1;
                            }
                            if (tj.type == .Operator and std.mem.eql(u8, tj.data.sval.items, "[")) depthb += 1;
                            if (tj.type == .Symbol and tj.data.cval == ']') {
                                if (depthb > 0) depthb -= 1;
                            }

                            if (depthp == 0 and depthb == 0) {
                                if (tj.type == .Symbol and tj.data.cval == ';') break;

                                if (tj.type == .Keyword) {
                                    const w = tj.data.sval.items;
                                    for (stmt_keywords) |skw| {
                                        if (std.mem.eql(u8, w, skw)) {
                                            stmt_start = jfind;
                                            break;
                                        }
                                    }
                                    if (stmt_start != null) break;
                                }

                                if (tj.type == .Operator) {
                                    const op = tj.data.sval.items;
                                    for (assign_ops) |aop| {
                                        if (std.mem.eql(u8, op, aop)) {
                                            stmt_start = prev_sig_at_depth0;
                                            break;
                                        }
                                    }
                                    if (stmt_start != null) break;
                                }

                                prev_sig_at_depth0 = jfind;
                            }
                        }

                        if (stmt_start) |ss| {
                            wrap_cond_open_at = jcond;
                            wrap_cond_close_before = ss;
                        }
                    }
                }
            }
            if (std.mem.eql(u8, kw2, "else") or std.mem.eql(u8, kw2, "for") or std.mem.eql(u8, kw2, "fit") or std.mem.eql(u8, kw2, "defer")) {
                pending_control_block_open = true;
            }
        }

        // Handle closing brace with optional same-line `elif`/`else`.
        if (t2.type == .Symbol and t2.data.cval == '}') {
            // Closing brace of an inline `fit` arm body: emit ` }` on the same line
            // (the open `{` did not push to brace_stack, so match by index).
            if (inline_arm_close) |close_i| {
                if (idx == close_i) {
                    inline_arm_close = null;
                    const last = if (state.out.items.len > 0) state.out.items[state.out.items.len - 1] else 0;
                    // An EMPTY inline body (`{}`) stays compact -- only pad with a
                    // space before `}` when there's actual content between the
                    // braces (`{ ret x; }`), matching the `{}` convention used
                    // for empty bodies elsewhere.
                    if (last != ' ' and last != '{') try state.out.append(' ');
                    try state.out.append('}');
                    // A fit-branch separator comma must stay glued to THIS arm's close
                    // (`... },`) rather than leading the next line (`, next -> ...`).
                    // Mirror the multi-line arm path: look past trivia for a `,` and,
                    // when there is no intervening comment, consume + glue it here.
                    {
                        var jc = idx + 1;
                        var saw_comment = false;
                        while (jc < toks.len and (toks[jc].type == .NewLine or toks[jc].type == .Comment)) : (jc += 1) {
                            if (toks[jc].type == .Comment) saw_comment = true;
                        }
                        if (!saw_comment and jc < toks.len and toks[jc].type == .Operator and std.mem.eql(u8, toks[jc].data.sval.items, ",")) {
                            try state.out.append(',');
                            idx = jc; // skip the comma; the next arm starts on a fresh line
                        }
                    }
                    // The next fit arm (or the fit's own closing `}`) starts on a new
                    // line. Emit only the newline; the standard line-start path emits
                    // the indent for the next token (avoid double-indenting).
                    try state.out.append('\n');
                    state.at_line_start.* = true;
                    state.prev_token.* = null;
                    continue;
                }
            }
            const popped_brace_kind = if (brace_stack.items.len > 0) brace_stack.items[brace_stack.items.len - 1] else .plain_block;
            if (brace_stack.items.len > 0) _ = brace_stack.pop();
            const is_block_close = popped_brace_kind != .not_a_block;

            if (!is_block_close) {
                try state.out.append('}');
                state.prev_token.* = t2;
                continue;
            }

            switch (popped_brace_kind) {
                .decl_block => if (decl_block_depth > 0) {
                    decl_block_depth -= 1;
                },
                .enum_block => if (enum_block_depth > 0) {
                    enum_block_depth -= 1;
                },
                .function_body => if (function_body_depth > 0) {
                    function_body_depth -= 1;
                },
                .plain_block, .not_a_block => {},
            }
            if (!state.at_line_start.*) try state.out.append('\n');
            if (state.indent.* > 0) state.indent.* -= 1;
            try state.out.appendNTimes(' ', state.indent.* * fmt_indent_width);
            try state.out.append('}');

            // If a fit-branch separator comma immediately follows, keep it on the same line:
            // `} , Next -> {` becomes `},\nNext -> {`.
            {
                var j2 = idx + 1;
                var saw_comment: bool = false;
                while (j2 < toks.len and (toks[j2].type == .NewLine or toks[j2].type == .Comment)) : (j2 += 1) {
                    if (toks[j2].type == .Comment) saw_comment = true;
                }
                if (!saw_comment and j2 < toks.len and toks[j2].type == .Operator and std.mem.eql(u8, toks[j2].data.sval.items, ",")) {
                    try state.out.append(',');
                    // Skip the comma token; formatting continues after it.
                    idx = j2;
                }
            }

            // Look ahead for `elif`/`else`.
            var j2 = idx + 1;
            while (j2 < toks.len and (toks[j2].type == .NewLine or toks[j2].type == .Comment)) : (j2 += 1) {}
            if (j2 < toks.len and toks[j2].type == .Keyword) {
                const kw2 = toks[j2].data.sval.items;
                if (std.mem.eql(u8, kw2, "elif") or std.mem.eql(u8, kw2, "else")) {
                    try state.out.append(' ');
                    state.at_line_start.* = false;
                    state.prev_token.* = t2;
                    continue;
                }
            }

            try state.out.append('\n');
            state.at_line_start.* = true;

            // Add a blank line between top-level function declarations.
            if (state.indent.* == 0) {
                var k2 = idx + 1;
                while (k2 < toks.len and (toks[k2].type == .NewLine or toks[k2].type == .Comment)) : (k2 += 1) {}
                if (k2 < toks.len and toks[k2].type == .Keyword and is_top_level_construct_keyword(toks[k2].data.sval.items)) {
                    try ensureBlankLine(state.out);
                    state.at_line_start.* = true;
                }
            }

            state.prev_token.* = t2;
            continue;
        }

        // Indent at start of line.
        if (state.at_line_start.*) {
            try state.out.appendNTimes(' ', state.indent.* * fmt_indent_width);
            state.at_line_start.* = false;
        }

        // An enum body (`enum E { Variant(Type*, ...), ... }`) is ALSO a
        // declaration-only context -- variant payload lists are type lists,
        // never executable code -- but tracks its own `enum_block_depth`
        // rather than `decl_block_depth` (an enum isn't an `impl`/`compound`/
        // `quirk`). Without this, a pointer-typed payload followed by
        // another payload (`Bin(chr, Type*, Type*)`, star followed by `,`)
        // fell through to non-declaration spacing and gained a stray space,
        // even on ALREADY-correctly-spaced input.
        const in_decl_only_ctx = in_fun_signature or (decl_block_depth > 0 and function_body_depth == 0) or (enum_block_depth > 0 and function_body_depth == 0);
        const generic_open = is_generic_angle_open(toks, idx, in_decl_only_ctx);
        const prev_sig_idx = prev_significant_index(toks, idx);
        const prev_sig = if (prev_sig_idx) |pi| toks[pi] else null;
        const prev_prev_sig_idx = if (prev_sig_idx) |pi| prev_significant_index(toks, pi) else null;
        const prev_prev_sig = if (prev_prev_sig_idx) |ppi| toks[ppi] else null;
        const prev_sig_is_rparen = prev_sig != null and prev_sig.?.type == .Symbol and prev_sig.?.data.cval == ')';
        const prev_prev_is_rparen = prev_prev_sig != null and prev_prev_sig.?.type == .Symbol and prev_prev_sig.?.data.cval == ')';
        const prev_sig_is_type_after_paren = prev_prev_is_rparen and prev_sig != null and isLikelyTypeToken(prev_sig.?);
        const prev_sig_is_arrow = prev_sig != null and prev_sig.?.type == .Operator and std.mem.eql(u8, prev_sig.?.data.sval.items, "->");
        const prev_sig_is_comma = prev_sig != null and prev_sig.?.type == .Operator and std.mem.eql(u8, prev_sig.?.data.sval.items, ",");
        const prev_sig_is_semicolon = prev_sig != null and prev_sig.?.type == .Symbol and prev_sig.?.data.cval == ';';
        const prev_sig_is_lbrace = prev_sig != null and prev_sig.?.type == .Symbol and prev_sig.?.data.cval == '{';
        const paren_before_brace = has_paren_before_brace(toks, idx);
        const is_block_brace = t2.type == .Symbol and t2.data.cval == '{' and
            (pending_decl_block_open or pending_enum_block_open or in_fun_signature or in_test_signature or pending_control_block_open or prev_sig_is_rparen or prev_sig_is_type_after_paren or paren_before_brace or prev_sig_is_arrow or prev_sig_is_comma or prev_sig_is_semicolon or prev_sig_is_lbrace);

        // Decide whether to add a space before this token.
        if (state.prev_token.*) |pt2| {
            const needs_space = blk: {
                const t2_is_equal = (t2.type == .Symbol and t2.data.cval == '=') or
                    (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "="));

                // Keep assignment and split `==`/`!=` readable after identifiers/prefixes.
                if (t2_is_equal and (is_word_like(pt2) or (pt2.type == .Symbol and is_closing_symbol(pt2.data.cval)))) {
                    break :blk true;
                }

                // When lexing produces split operator tokens, keep comparison/equality pairs
                // glued so we emit valid operators: <=, >=, !=, ==.
                if (t2.type == .Symbol and t2.data.cval == '=') {
                    if (pt2.type == .Symbol) {
                        const pc = pt2.data.cval;
                        if (pc == '<' or pc == '>' or pc == '!' or pc == '=') {
                            break :blk false;
                        }
                    }
                    if (pt2.type == .Operator) {
                        const pop = pt2.data.sval.items;
                        if (std.mem.eql(u8, pop, "<") or std.mem.eql(u8, pop, ">") or std.mem.eql(u8, pop, "!") or std.mem.eql(u8, pop, "=")) {
                            break :blk false;
                        }
                    }
                }
                if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "=")) {
                    if (pt2.type == .Symbol) {
                        const pc = pt2.data.cval;
                        if (pc == '<' or pc == '>' or pc == '!' or pc == '=') {
                            break :blk false;
                        }
                    }
                    if (pt2.type == .Operator) {
                        const pop = pt2.data.sval.items;
                        if (std.mem.eql(u8, pop, "<") or std.mem.eql(u8, pop, ">") or std.mem.eql(u8, pop, "!") or std.mem.eql(u8, pop, "=")) {
                            break :blk false;
                        }
                    }
                }
                if ((t2.type == .Symbol and t2.data.cval == '*') or
                    (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "*")))
                {
                    // Keep pointer type stars glued in declarations/signatures, including
                    // generic closes like `Channel<T>* value`.
                    if (isPointerTypeStarContext(toks, idx, pt2, in_decl_only_ctx)) {
                        break :blk false;
                    }
                }
                if (is_word_like(t2) and idx >= 2) {
                    const prev_of_star = toks[idx - 2];
                    if ((pt2.type == .Symbol and pt2.data.cval == '*') or
                        (pt2.type == .Operator and std.mem.eql(u8, pt2.data.sval.items, "*")))
                    {
                        if (isPointerTypeStarContext(toks, idx - 1, prev_of_star, in_decl_only_ctx)) break :blk true;
                    }
                }
                if (prev_unary_prefix) {
                    // Keep unary prefix operators glued to their operand: `-w`, `-1`, `+(x)`.
                    prev_unary_prefix = false;
                    break :blk false;
                }
                if (pt2.type == .Operator and (std.mem.eql(u8, pt2.data.sval.items, "=") or
                    std.mem.eql(u8, pt2.data.sval.items, "!=") or std.mem.eql(u8, pt2.data.sval.items, "==")) and t2.type == .Operator and
                    (std.mem.eql(u8, t2.data.sval.items, "&") or std.mem.eql(u8, t2.data.sval.items, "*") or
                        std.mem.eql(u8, t2.data.sval.items, "+") or std.mem.eql(u8, t2.data.sval.items, "-")))
                {
                    break :blk true;
                }
                if (pt2.type == .Keyword and (std.mem.eql(u8, pt2.data.sval.items, "ret") or std.mem.eql(u8, pt2.data.sval.items, "fit"))) {
                    // `ret *p` / `fit *self`: a space separates the keyword from the
                    // unary-prefixed operand (the `*`/`&` then glues to its operand).
                    if (t2.type == .Operator and (std.mem.eql(u8, t2.data.sval.items, "+") or std.mem.eql(u8, t2.data.sval.items, "-") or std.mem.eql(u8, t2.data.sval.items, "&") or std.mem.eql(u8, t2.data.sval.items, "*"))) {
                        break :blk true;
                    }
                    if (t2.type == .Symbol and (t2.data.cval == '+' or t2.data.cval == '-' or t2.data.cval == '&' or t2.data.cval == '*')) {
                        break :blk true;
                    }
                }
                if (t2.type == .Operator) {
                    const op2 = t2.data.sval.items;
                    if (std.mem.eql(u8, op2, "-") or std.mem.eql(u8, op2, "+") or std.mem.eql(u8, op2, "&") or std.mem.eql(u8, op2, "*")) {
                        const unary_ctx = blk_unary: {
                            if (pt2.type == .Keyword) {
                                const kw = pt2.data.sval.items;
                                if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for") or std.mem.eql(u8, kw, "fit") or std.mem.eql(u8, kw, "assert")) break :blk_unary true;
                            }
                            if (is_word_like(pt2)) break :blk_unary false;
                            if (pt2.type == .Symbol and is_closing_symbol(pt2.data.cval)) break :blk_unary false;
                            break :blk_unary true;
                        };
                        if (unary_ctx) {
                            // Keep unary prefixes glued to their operand (`-x`) but preserve
                            // a separator after binary operators (`x <= -1`, `a + -b`).
                            if (pt2.type == .Operator and operator_needs_spaces(pt2.data.sval.items)) break :blk true;
                            if (pt2.type == .Symbol) {
                                const pc = pt2.data.cval;
                                if (pc == '*' or pc == '+' or pc == '-' or pc == '/' or pc == '%' or pc == '<' or pc == '>' or pc == '=' or pc == '&' or pc == '|' or pc == '^' or pc == '!') {
                                    break :blk true;
                                }
                            }
                            break :blk false;
                        }
                    }
                }
                if (t2.type == .Symbol and (t2.data.cval == '&' or t2.data.cval == '*' or t2.data.cval == '+' or t2.data.cval == '-')) {
                    if (pt2.type == .Operator and (std.mem.eql(u8, pt2.data.sval.items, "=") or
                        std.mem.eql(u8, pt2.data.sval.items, "!=") or std.mem.eql(u8, pt2.data.sval.items, "=="))) break :blk true;
                    const unary_ctx = blk_unary_sym: {
                        if (pt2.type == .Keyword) {
                            const kw = pt2.data.sval.items;
                            if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for") or std.mem.eql(u8, kw, "fit") or std.mem.eql(u8, kw, "assert")) break :blk_unary_sym true;
                        }
                        if (is_word_like(pt2)) break :blk_unary_sym false;
                        if (pt2.type == .Symbol and is_closing_symbol(pt2.data.cval)) break :blk_unary_sym false;
                        break :blk_unary_sym true;
                    };
                    if (unary_ctx) {
                        if (pt2.type == .Operator and operator_needs_spaces(pt2.data.sval.items)) break :blk true;
                        if (pt2.type == .Symbol) {
                            const pc = pt2.data.cval;
                            if (pc == '*' or pc == '+' or pc == '-' or pc == '/' or pc == '%' or pc == '<' or pc == '>' or pc == '=' or pc == '&' or pc == '|' or pc == '^' or pc == '!') {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    }
                }
                if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "*") and isPointerTypeStarContext(toks, idx, pt2, in_decl_only_ctx)) {
                    // Pointer types: `Type* name` / `Type* {`.
                    break :blk false;
                }
                if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "*") and idx > 0) {
                    const prev_tok = toks[idx - 1];
                    if (prev_tok.type == .Identifier and prev_tok.data.sval.items.len > 0 and
                        (prev_tok.data.sval.items[0] >= 'A' and prev_tok.data.sval.items[0] <= 'Z') and
                        isPointerTypeStarContext(toks, idx, prev_tok, in_decl_only_ctx))
                    {
                        break :blk false;
                    }
                }
                if (pt2.type == .Keyword) {
                    const pkw2 = pt2.data.sval.items;
                    if (std.mem.eql(u8, pkw2, "if") or std.mem.eql(u8, pkw2, "elif")) {
                        // Always separate the keyword from the start of its condition, even if
                        // the condition starts with an inner grouping `(`.
                        break :blk true;
                    }
                    if (std.mem.eql(u8, pkw2, "await")) {
                        // Keep await as a keyword followed by an expression: `await (...)`.
                        break :blk true;
                    }
                    if (std.mem.eql(u8, pkw2, "imp")) {
                        // Always separate `imp` from the import path, even if it starts with dot-runs.
                        break :blk true;
                    }
                    // A leading-dot enum shorthand begins an expression, so it needs a
                    // space after an expression-introducing keyword: `ret .Number(n)`,
                    // `let x = .Some(1)` (the `=` case is already spaced). Without this
                    // the dot glues to the keyword (`ret.Number`). A bare `.` operator
                    // here is the shorthand; `obj.field` never has a keyword as `pt2`.
                    if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, ".")) {
                        if (std.mem.eql(u8, pkw2, "ret") or std.mem.eql(u8, pkw2, "for")) break :blk true;
                    }
                }
                if (t2.type == .Symbol) {
                    const c2 = t2.data.cval;
                    if (c2 == '*' and idx > 0) {
                        const prev_tok = toks[idx - 1];
                        if ((prev_tok.type == .Identifier and prev_tok.data.sval.items.len > 0 and (prev_tok.data.sval.items[0] >= 'A' and prev_tok.data.sval.items[0] <= 'Z')) or
                            (prev_tok.type == .Keyword and is_builtin_type_keyword(prev_tok.data.sval.items)))
                        {
                            if (isPointerTypeStarContext(toks, idx, prev_tok, in_decl_only_ctx)) {
                                break :blk false;
                            }
                        }
                    }
                    if ((c2 == '<' and (generic_open or generic_angle_depth > 0)) or (c2 == '>' and generic_angle_depth > 0)) {
                        break :blk false;
                    }
                    if (c2 == ':') break :blk isForLoopColonContext(toks, idx);
                    if (c2 == ',' or c2 == ';' or c2 == ')' or c2 == ']' or c2 == '}') break :blk false;
                    if (c2 == '{') break :blk is_block_brace;
                    if (c2 == '*' or c2 == '+' or c2 == '-' or c2 == '/' or c2 == '%' or c2 == '<' or c2 == '>' or c2 == '=' or c2 == '&' or c2 == '|' or c2 == '^') {
                        break :blk true;
                    }
                    if (c2 == '(' or c2 == '[') {
                        // No space for calls/indexing: `foo(`, `arr[`.
                        break :blk false;
                    }
                }
                if (pt2.type == .Symbol) {
                    const pc2 = pt2.data.cval;
                    if (pc2 == '>' and (t2.type == .Symbol and t2.data.cval == '(')) break :blk false;
                    if ((pc2 == '<' and generic_angle_depth > 0) or (pc2 == '>' and generic_angle_depth > 0)) break :blk false;
                    if (pc2 == '*' or pc2 == '+' or pc2 == '-' or pc2 == '/' or pc2 == '%' or pc2 == '<' or pc2 == '>' or pc2 == '=' or pc2 == '&' or pc2 == '|' or pc2 == '^') break :blk true;
                    if (pc2 == '(' or pc2 == '[' or pc2 == '{') break :blk false;
                }
                if (t2.type == .Operator and (std.mem.eql(u8, t2.data.sval.items, "(") or std.mem.eql(u8, t2.data.sval.items, "["))) {
                    if (pt2.type == .Symbol and pt2.data.cval == '>') break :blk false;
                    if (pt2.type == .Operator and std.mem.eql(u8, pt2.data.sval.items, ">")) break :blk false;
                    // A string literal is never a callee/index target -- unlike an
                    // identifier, `"name"(` isn't a call. The only place this shape
                    // occurs is `fuzz "name" (data, len) { ... }`, whose parameter
                    // list must not glue to the description string.
                    if (pt2.type == .String) break :blk true;
                    // A statement keyword taking a parenthesized OPERAND (`ret (x) & y;`,
                    // `if (a) {`, `fit (x) {`) is not a call/index -- unlike a real
                    // callee name, it must not glue to the paren (`ret(x)` reads as a
                    // function call). `fun`/type-name-like keywords are NOT included
                    // here since those legitimately precede a real parameter list.
                    if (pt2.type == .Keyword) {
                        const kw = pt2.data.sval.items;
                        if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for") or std.mem.eql(u8, kw, "fit") or std.mem.eql(u8, kw, "assert") or std.mem.eql(u8, kw, "await")) {
                            break :blk true;
                        }
                    }
                    // Distinguish grouping after spaced operators (e.g. `|| (`) from calls/indexing (e.g. `foo(`).
                    if (pt2.type == .Operator and operator_needs_spaces(pt2.data.sval.items)) break :blk true;
                    break :blk false;
                }
                // --- PATCH: Always insert a space after ==, !=, or = before dot shorthand enum (e.g., c == .Blue) ---
                if (pt2.type == .Operator and (std.mem.eql(u8, pt2.data.sval.items, "==") or
                    std.mem.eql(u8, pt2.data.sval.items, "=") or
                    std.mem.eql(u8, pt2.data.sval.items, "!=")) and t2.type == .Operator and t2.data.sval.items.len > 0 and t2.data.sval.items[0] == '.')
                {
                    break :blk true;
                }
                // --- END PATCH ---
                if (pt2.type == .Operator and (std.mem.eql(u8, pt2.data.sval.items, "<") or
                    std.mem.eql(u8, pt2.data.sval.items, "<=") or
                    std.mem.eql(u8, pt2.data.sval.items, ">") or
                    std.mem.eql(u8, pt2.data.sval.items, ">=")) and t2.type == .Operator and t2.data.sval.items.len > 0 and t2.data.sval.items[0] == '.')
                {
                    break :blk true;
                }
                if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "<") and (generic_open or generic_angle_depth > 0)) {
                    break :blk false;
                }
                if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, ">") and generic_angle_depth > 0) {
                    break :blk false;
                }
                if (t2.type == .Operator and generic_close_count(t2) > 0 and generic_angle_depth > 0) {
                    break :blk false;
                }
                if (pt2.type == .Operator and std.mem.eql(u8, pt2.data.sval.items, "<") and generic_angle_depth > 0) {
                    break :blk false;
                }
                if (pt2.type == .Operator and generic_close_count(pt2) > 0 and generic_angle_depth > 0) {
                    break :blk false;
                }
                if (t2.type == .Operator) {
                    if (std.mem.eql(u8, t2.data.sval.items, ":")) break :blk isForLoopColonContext(toks, idx);
                    break :blk operator_needs_spaces(t2.data.sval.items);
                }
                if (pt2.type == .Operator) {
                    if (std.mem.eql(u8, pt2.data.sval.items, ":") and isForLoopColonContext(toks, idx - 1)) break :blk true;
                    break :blk operator_needs_spaces(pt2.data.sval.items);
                }
                if (is_word_like(pt2) and is_word_like(t2)) break :blk true;
                if (pt2.type == .Symbol and is_closing_symbol(pt2.data.cval) and is_word_like(t2)) break :blk true;
                break :blk false;
            };
            if (needs_space) {
                const last2 = if (state.out.items.len > 0) state.out.items[state.out.items.len - 1] else 0;
                if (last2 != ' ' and last2 != '\n' and last2 != '\t') try state.out.append(' ');
            }
        }

        // Emit token.
        if (t2.type == .Symbol) {
            const c2 = t2.data.cval;
            if (c2 == '{') {
                // Short `fit` arm body after `->`: keep it on one line when it holds
                // a single simple statement and fits the width budget.
                if (is_block_brace and prev_sig_is_arrow and inline_arm_close == null) {
                    if (fitArmInlineClose(toks, idx, source, line_starts, state.allocator, currentColumn(state.out))) |close_i| {
                        inline_arm_close = close_i;
                        try state.out.append('{');
                        // An EMPTY inline body (`{}`, close immediately follows
                        // open) stays compact -- don't pre-emptively add the
                        // "{ content }" padding space when there's no content.
                        // The matching close-brace handler has its own guard
                        // for this, but that only prevents a SECOND space; the
                        // one written here happens first and unconditionally.
                        if (close_i != idx + 1) try state.out.append(' ');
                        state.at_line_start.* = false;
                        state.prev_token.* = null;
                        continue;
                    }
                }
                if (is_block_brace) {
                    var brace_kind: BraceKind = .plain_block;
                    if (pending_decl_block_open) {
                        decl_block_depth += 1;
                        pending_decl_block_open = false;
                        brace_kind = .decl_block;
                    }
                    if (pending_enum_block_open) {
                        enum_block_depth += 1;
                        pending_enum_block_open = false;
                        brace_kind = .enum_block;
                    }
                    if (pending_control_block_open) pending_control_block_open = false;
                    if (in_fun_signature) {
                        in_fun_signature = false;
                        function_body_depth += 1;
                        brace_kind = .function_body;
                    } else if (in_test_signature) {
                        in_test_signature = false;
                        function_body_depth += 1;
                        brace_kind = .function_body;
                    } else if (function_body_depth == 0 and decl_block_depth > 0 and !pending_decl_block_open and !pending_enum_block_open and !pending_control_block_open and (prev_sig_is_rparen or prev_sig_is_type_after_paren or paren_before_brace)) {
                        function_body_depth = 1;
                        brace_kind = .function_body;
                    } else if (function_body_depth > 0) {
                        function_body_depth += 1;
                        brace_kind = .function_body;
                    }
                    try brace_stack.append(brace_kind);
                    try state.out.append('{');
                    try state.out.append('\n');
                    state.indent.* += 1;
                    state.at_line_start.* = true;
                    state.prev_token.* = null;
                    continue;
                }
                try brace_stack.append(.not_a_block);
                try state.out.append('{');
                state.prev_token.* = t2;
                continue;
            }
            if (c2 == ';') {
                if (in_fun_signature) in_fun_signature = false;
                if (enum_block_depth > 0) {
                    try state.out.append(',');
                } else {
                    try state.out.append(';');
                }
                // Inside an inline `fit` arm body the statement separator stays on
                // the same line (`{ ret v; }`); a `}` close follows shortly.
                if (inline_arm_close != null) {
                    try state.out.append(' ');
                    state.prev_token.* = null;
                    continue;
                }
                try state.out.append('\n');
                state.at_line_start.* = true;
                state.prev_token.* = null;
                continue;
            }
            if (c2 == ',') {
                try state.out.append(',');
                // A comma inside an open generic argument list (e.g. the one
                // between `str` and `GlobalSymbolInfo` in `Map<str,
                // GlobalSymbolInfo>`) belongs to the type expression, not to
                // the wrap group's own item list -- `bracket_depth` doesn't
                // track `<`/`>` nesting, so without this guard such a comma
                // sat at the SAME depth as the group's real item separators
                // and got a spurious line break in the middle of the type.
                const in_wrap = generic_angle_depth == 0 and wrap_item_depth.items.len > 0 and bracket_depth == wrap_item_depth.items[wrap_item_depth.items.len - 1];
                if (in_wrap) {
                    // Newline only; the line-start path indents the next item.
                    try state.out.append('\n');
                    state.at_line_start.* = true;
                } else if (enum_block_depth > 0 and enum_payload_paren_depth == 0) {
                    try state.out.append('\n');
                    state.at_line_start.* = true;
                } else {
                    try state.out.append(' ');
                }
                state.prev_token.* = null;
                continue;
            }
            if (c2 == ':') {
                try state.out.append(':');
                try state.out.append(' ');
                state.prev_token.* = null;
                continue;
            }
            try state.out.append(c2);
            state.prev_token.* = t2;
            continue;
        }

        if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, ",")) {
            try state.out.append(',');
            // See the matching guard above: a comma inside an open generic
            // argument list is part of the type, not a wrap-group separator.
            const in_wrap = generic_angle_depth == 0 and wrap_item_depth.items.len > 0 and bracket_depth == wrap_item_depth.items[wrap_item_depth.items.len - 1];
            if (in_wrap) {
                // Newline only; the line-start path indents the next item.
                try state.out.append('\n');
                state.at_line_start.* = true;
            } else if (enum_block_depth > 0 and enum_payload_paren_depth == 0) {
                try state.out.append('\n');
                state.at_line_start.* = true;
            } else {
                try state.out.append(' ');
            }
            state.prev_token.* = null;
            continue;
        }

        if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, ":")) {
            try state.out.append(':');
            try state.out.append(' ');
            state.prev_token.* = null;
            continue;
        }

        if (t2.type == .Operator and (std.mem.eql(u8, t2.data.sval.items, "(") or std.mem.eql(u8, t2.data.sval.items, "["))) {
            const s2 = try token_text(state.allocator, t2, source, line_starts);
            defer state.allocator.free(s2);
            try state.out.appendSlice(s2);

            // Width-based wrapping: if this comma group, rendered on one line from
            // the current column, would exceed the budget, switch it to one-item-
            // per-line. We only wrap groups that have a top-level comma (multiple
            // items) — single-arg calls / index expressions never wrap.
            const col = currentColumn(state.out);
            if (try measureWrapGroup(state.allocator, toks, idx, source, line_starts)) |g| {
                if (g.has_comma and col + g.width > fmt_max_line_width) {
                    try wrap_close_stack.append(g.close_idx);
                    try wrap_item_depth.append(bracket_depth); // items live at this depth
                    state.indent.* += 1;
                    // Emit only the newline; the standard line-start path emits the
                    // indent for the first item (avoid double-indenting).
                    try state.out.append('\n');
                    state.at_line_start.* = true;
                    state.prev_token.* = null;
                    continue;
                }
            }
            state.prev_token.* = t2;
            continue;
        }

        const s2_raw = try token_text(state.allocator, t2, source, line_starts);
        const s2 = if (t2.type == .String and t2.is_raw_string)
            try reindentRawStringContinuations(state.allocator, s2_raw, state.indent.* * fmt_indent_width)
        else
            s2_raw;
        defer state.allocator.free(s2_raw);
        defer if (s2.ptr != s2_raw.ptr) state.allocator.free(s2);
        try state.out.appendSlice(s2);

        // Track unary prefix ops so we don't insert a space after them.
        if (t2.type == .Operator) {
            const op2 = t2.data.sval.items;
            if ((std.mem.eql(u8, op2, "-") or std.mem.eql(u8, op2, "+") or std.mem.eql(u8, op2, "&") or std.mem.eql(u8, op2, "*") or std.mem.eql(u8, op2, "!"))) {
                const is_pointer_decl_star = std.mem.eql(u8, op2, "*") and blk_ptr: {
                    const prev = state.prev_token.*;
                    if (prev == null) break :blk_ptr false;
                    break :blk_ptr isPointerTypeStarContext(toks, idx, prev.?, in_decl_only_ctx);
                };
                if (is_pointer_decl_star) {
                    state.prev_token.* = t2;
                    continue;
                }

                const unary_ctx = blk: {
                    const prev = state.prev_token.*;
                    if (prev == null) break :blk true;
                    const pt = prev.?;
                    if (pt.type == .Keyword) {
                        const kw = pt.data.sval.items;
                        // Keywords that are followed by an expression.
                        if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for") or std.mem.eql(u8, kw, "fit") or std.mem.eql(u8, kw, "assert")) break :blk true;
                    }
                    if (is_word_like(pt)) break :blk false;
                    if (pt.type == .Symbol and is_closing_symbol(pt.data.cval)) break :blk false;
                    break :blk true;
                };
                if (unary_ctx) prev_unary_prefix = true;
            }
        }
        if (generic_open) {
            generic_angle_depth += 1;
        } else {
            const closes = generic_close_count(t2);
            if (closes > 0 and generic_angle_depth > 0) {
                if (closes >= generic_angle_depth) {
                    generic_angle_depth = 0;
                } else {
                    generic_angle_depth -= closes;
                }
            }
        }
        state.prev_token.* = t2;
    }
}

pub fn format_file_in_place(allocator: mem.Allocator, io: std.Io, input_file: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, input_file, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(source);

    const out = try format_source(allocator, input_file, source);
    defer allocator.free(out);

    // Overwrite input file in-place.
    var tp = try codegen.TranspileProcess.init_rw(
        allocator,
        input_file,
        "__fmt_unused__.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();
    try tp.ifile.writePositionalAll(io, out, 0);
    try tp.ifile.setLength(io, out.len);
}

/// Format `source` (the contents of `input_file`) using the pure token-based
/// formatter and return the formatted text as an allocator-owned slice. This is
/// lexing-only — it never transpiles or typechecks, so it is cheap and has no
/// dependency on imports/stdlib. `input_file` is used only for lexing (the file
/// must exist on disk with the given content). The output is byte-identical to
/// what `format_file_in_place` writes.
pub fn format_source(allocator: mem.Allocator, input_file: []const u8, source: []const u8) ![]u8 {
    var line_starts = ArrayList(usize).init(allocator);
    defer line_starts.deinit();
    try line_starts.append(0);
    for (source, 0..) |c, i| {
        if (c == '\n') {
            try line_starts.append(i + 1);
        }
    }

    // Lex tokens from the file.
    var tp = try codegen.TranspileProcess.init_rw(
        allocator,
        input_file,
        "__fmt_unused__.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();
    var lp = lexer.LexProcess.init(&tp);
    defer lp.deinit();
    try lp.lex();

    var out = ArrayList(u8).init(allocator);
    defer out.deinit();

    var indent: usize = 0;
    var at_line_start = true;
    var prev_token: ?token.Token = null;
    var in_doc_fence = false;

    const tokens = tp.tokens.items();

    // Partition top-level imports + global vars into groups.
    var imports = ArrayList(token.Token).init(allocator);
    defer imports.deinit();
    var globals = ArrayList(token.Token).init(allocator);
    defer globals.deinit();
    var rest = ArrayList(token.Token).init(allocator);
    defer rest.deinit();
    var pending_comments = ArrayList(token.Token).init(allocator);
    defer pending_comments.deinit();
    var pending_group: ?FmtTopLevelGroup = null;
    var pending_group_tokens = ArrayList(token.Token).init(allocator);
    defer pending_group_tokens.deinit();

    var brace_depth: isize = 0;
    var paren_depth: isize = 0;
    var bracket_depth: isize = 0;
    var can_start_stmt = true;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type == .NewLine) {
            // Keep newlines so the emitter can preserve blank lines (2+ newlines).
            // A single newline is treated as normal whitespace by the emitter.
            if (brace_depth == 0 and pending_comments.items.len > 0) {
                try pending_comments.append(t);
            } else {
                try rest.append(t);
            }
            continue;
        }

        const is_top = brace_depth == 0;
        const is_stmt_start = is_top and paren_depth == 0 and bracket_depth == 0 and can_start_stmt;

        if (is_top and t.type == .Comment) {
            try pending_comments.append(t);
            continue;
        }

        const is_kw = t.type == .Keyword;
        const kw = if (is_kw) t.data.sval.items else "";

        const starts_import_stmt = is_stmt_start and is_kw and std.mem.eql(u8, kw, "imp");
        const starts_global_stmt = is_stmt_start and is_kw and (is_builtin_type_keyword(kw) or std.mem.eql(u8, kw, "let"));

        if (is_stmt_start and pending_group != null and !starts_import_stmt and !starts_global_stmt) {
            try appendAll(&rest, pending_group_tokens.items);
            pending_group_tokens.clearRetainingCapacity();
            pending_group = null;
        }

        if (is_stmt_start and is_kw) {
            if (warning_control_group_for_tokens(tokens, i)) |group| {
                var stmt = ArrayList(token.Token).init(allocator);
                defer stmt.deinit();
                try appendAll(&stmt, pending_comments.items);
                pending_comments.clearRetainingCapacity();

                try stmt.append(t);

                var j: usize = i + 1;
                while (j < tokens.len) : (j += 1) {
                    const tt = tokens[j];
                    if (tt.type == .NewLine) continue;
                    try stmt.append(tt);
                    if (tt.type == .Symbol and tt.data.cval == ';') break;
                }

                if (pending_group != null) {
                    try appendAll(&rest, pending_group_tokens.items);
                    pending_group_tokens.clearRetainingCapacity();
                }
                pending_group = group;
                try appendAll(&pending_group_tokens, stmt.items);
                i = j;
                can_start_stmt = true;
                continue;
            }
        }

        if (starts_import_stmt or starts_global_stmt) {
            // Collect up to ';'
            var stmt = ArrayList(token.Token).init(allocator);
            defer stmt.deinit();
            if (pending_group) |group| {
                const matches_group = (group == .imports and starts_import_stmt) or (group == .globals and starts_global_stmt);
                if (matches_group) {
                    try appendAll(&stmt, pending_group_tokens.items);
                    pending_group_tokens.clearRetainingCapacity();
                    pending_group = null;
                } else {
                    try appendAll(&rest, pending_group_tokens.items);
                    pending_group_tokens.clearRetainingCapacity();
                    pending_group = null;
                }
            }
            try appendAll(&stmt, pending_comments.items);
            pending_comments.clearRetainingCapacity();

            try stmt.append(t);

            var j: usize = i + 1;
            while (j < tokens.len) : (j += 1) {
                const tt = tokens[j];
                if (tt.type == .NewLine) continue;
                try stmt.append(tt);
                if (tt.type == .Symbol and tt.data.cval == ';') {
                    break;
                }
            }

            if (starts_import_stmt) {
                try appendAll(&imports, stmt.items);
            } else {
                try appendAll(&globals, stmt.items);
            }

            i = j;
            can_start_stmt = true;
            continue;
        }

        // Not a top-level import/global-var statement: keep in place.
        if (pending_comments.items.len > 0) {
            try appendAll(&rest, pending_comments.items);
            pending_comments.clearRetainingCapacity();
        }
        try rest.append(t);

        // Track structural depth and statement boundaries.
        if (t.type == .Operator) {
            if (std.mem.eql(u8, t.data.sval.items, "(")) paren_depth += 1;
            if (std.mem.eql(u8, t.data.sval.items, "[")) bracket_depth += 1;
        }
        if (t.type == .Symbol) {
            if (t.data.cval == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            }
            if (t.data.cval == ']') {
                if (bracket_depth > 0) bracket_depth -= 1;
            }
            if (t.data.cval == '{') brace_depth += 1;
            if (t.data.cval == '}' and brace_depth > 0) brace_depth -= 1;
            if (t.data.cval == ';' and brace_depth == 0) {
                can_start_stmt = true;
            } else if (t.data.cval == '}' and brace_depth == 0) {
                can_start_stmt = true;
            } else if (t.data.cval != ';') {
                can_start_stmt = false;
            }
        } else {
            // Any non-comment, non-newline token consumes the statement start.
            can_start_stmt = false;
        }
    }

    if (pending_comments.items.len > 0) {
        try appendAll(&rest, pending_comments.items);
        pending_comments.clearRetainingCapacity();
    }
    if (pending_group != null) {
        try appendAll(&rest, pending_group_tokens.items);
        pending_group_tokens.clearRetainingCapacity();
        pending_group = null;
    }

    var state: EmitState = .{ .indent = &indent, .at_line_start = &at_line_start, .prev_token = &prev_token, .out = &out, .allocator = allocator, .in_doc_fence = &in_doc_fence };

    if (imports.items.len > 0) {
        try emitTokens(&state, imports.items, source, line_starts.items);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.append('\n');
        at_line_start = true;
        prev_token = null;
    }

    if (globals.items.len > 0) {
        try emitTokens(&state, globals.items, source, line_starts.items);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.append('\n');
        at_line_start = true;
        prev_token = null;
    }

    try emitTokens(&state, rest.items, source, line_starts.items);

    // Align consecutive trailing comments to a common column.
    try alignTrailingComments(allocator, &out);

    // Ensure exactly one trailing newline.
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append('\n');
    }

    return out.toOwnedSlice();
}

/// Checks whether `input_file` is already correctly formatted, without modifying it.
/// Returns `true` if the file is already formatted, `false` if formatting would change it.
pub fn format_file_check(allocator: mem.Allocator, io: std.Io, input_file: []const u8) !bool {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, input_file, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(source);

    var line_starts = ArrayList(usize).init(allocator);
    defer line_starts.deinit();
    try line_starts.append(0);
    for (source, 0..) |c, idx| {
        if (c == '\n') {
            try line_starts.append(idx + 1);
        }
    }

    var tp = try codegen.TranspileProcess.init_rw(
        allocator,
        input_file,
        "__fmt_unused__.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();
    var lp = lexer.LexProcess.init(&tp);
    defer lp.deinit();
    try lp.lex();

    var out = ArrayList(u8).init(allocator);
    defer out.deinit();

    var indent: usize = 0;
    var at_line_start = true;
    var prev_token: ?token.Token = null;
    var in_doc_fence = false;

    const tokens = tp.tokens.items();

    var imports = ArrayList(token.Token).init(allocator);
    defer imports.deinit();
    var globals = ArrayList(token.Token).init(allocator);
    defer globals.deinit();
    var rest = ArrayList(token.Token).init(allocator);
    defer rest.deinit();
    var pending_comments = ArrayList(token.Token).init(allocator);
    defer pending_comments.deinit();
    var pending_group: ?FmtTopLevelGroup = null;
    var pending_group_tokens = ArrayList(token.Token).init(allocator);
    defer pending_group_tokens.deinit();

    var brace_depth: isize = 0;
    var paren_depth: isize = 0;
    var bracket_depth: isize = 0;
    var can_start_stmt = true;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type == .NewLine) {
            if (brace_depth == 0 and pending_comments.items.len > 0) {
                try pending_comments.append(t);
            } else {
                try rest.append(t);
            }
            continue;
        }

        const is_top = brace_depth == 0;
        const is_stmt_start = is_top and paren_depth == 0 and bracket_depth == 0 and can_start_stmt;

        if (is_top and t.type == .Comment) {
            try pending_comments.append(t);
            continue;
        }

        const is_kw = t.type == .Keyword;
        const kw = if (is_kw) t.data.sval.items else "";

        const starts_import_stmt = is_stmt_start and is_kw and std.mem.eql(u8, kw, "imp");
        const starts_global_stmt = is_stmt_start and is_kw and (is_builtin_type_keyword(kw) or std.mem.eql(u8, kw, "let"));

        if (is_stmt_start and pending_group != null and !starts_import_stmt and !starts_global_stmt) {
            try appendAll(&rest, pending_group_tokens.items);
            pending_group_tokens.clearRetainingCapacity();
            pending_group = null;
        }

        if (is_stmt_start and is_kw) {
            if (warning_control_group_for_tokens(tokens, i)) |group| {
                var stmt = ArrayList(token.Token).init(allocator);
                defer stmt.deinit();
                try appendAll(&stmt, pending_comments.items);
                pending_comments.clearRetainingCapacity();

                try stmt.append(t);

                var j: usize = i + 1;
                while (j < tokens.len) : (j += 1) {
                    const tt = tokens[j];
                    if (tt.type == .NewLine) continue;
                    try stmt.append(tt);
                    if (tt.type == .Symbol and tt.data.cval == ';') break;
                }

                if (pending_group != null) {
                    try appendAll(&rest, pending_group_tokens.items);
                    pending_group_tokens.clearRetainingCapacity();
                }
                pending_group = group;
                try appendAll(&pending_group_tokens, stmt.items);
                i = j;
                can_start_stmt = true;
                continue;
            }
        }

        if (starts_import_stmt or starts_global_stmt) {
            var stmt = ArrayList(token.Token).init(allocator);
            defer stmt.deinit();
            if (pending_group) |group| {
                const matches_group = (group == .imports and starts_import_stmt) or (group == .globals and starts_global_stmt);
                if (matches_group) {
                    try appendAll(&stmt, pending_group_tokens.items);
                    pending_group_tokens.clearRetainingCapacity();
                    pending_group = null;
                } else {
                    try appendAll(&rest, pending_group_tokens.items);
                    pending_group_tokens.clearRetainingCapacity();
                    pending_group = null;
                }
            }
            try appendAll(&stmt, pending_comments.items);
            pending_comments.clearRetainingCapacity();

            try stmt.append(t);

            var j: usize = i + 1;
            while (j < tokens.len) : (j += 1) {
                const tt = tokens[j];
                if (tt.type == .NewLine) continue;
                try stmt.append(tt);
                if (tt.type == .Symbol and tt.data.cval == ';') {
                    break;
                }
            }

            if (starts_import_stmt) {
                try appendAll(&imports, stmt.items);
            } else {
                try appendAll(&globals, stmt.items);
            }

            i = j;
            can_start_stmt = true;
            continue;
        }

        if (pending_comments.items.len > 0) {
            try appendAll(&rest, pending_comments.items);
            pending_comments.clearRetainingCapacity();
        }
        try rest.append(t);

        if (t.type == .Operator) {
            if (std.mem.eql(u8, t.data.sval.items, "(")) paren_depth += 1;
            if (std.mem.eql(u8, t.data.sval.items, "[")) bracket_depth += 1;
        }
        if (t.type == .Symbol) {
            if (t.data.cval == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            }
            if (t.data.cval == ']') {
                if (bracket_depth > 0) bracket_depth -= 1;
            }
            if (t.data.cval == '{') brace_depth += 1;
            if (t.data.cval == '}' and brace_depth > 0) brace_depth -= 1;
            if (t.data.cval == ';' and brace_depth == 0) {
                can_start_stmt = true;
            } else if (t.data.cval == '}' and brace_depth == 0) {
                can_start_stmt = true;
            } else if (t.data.cval != ';') {
                can_start_stmt = false;
            }
        } else {
            can_start_stmt = false;
        }
    }

    if (pending_comments.items.len > 0) {
        try appendAll(&rest, pending_comments.items);
        pending_comments.clearRetainingCapacity();
    }
    if (pending_group != null) {
        try appendAll(&rest, pending_group_tokens.items);
        pending_group_tokens.clearRetainingCapacity();
        pending_group = null;
    }

    var state: EmitState = .{ .indent = &indent, .at_line_start = &at_line_start, .prev_token = &prev_token, .out = &out, .allocator = allocator, .in_doc_fence = &in_doc_fence };

    if (imports.items.len > 0) {
        try emitTokens(&state, imports.items, source, line_starts.items);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.append('\n');
        at_line_start = true;
        prev_token = null;
    }

    if (globals.items.len > 0) {
        try emitTokens(&state, globals.items, source, line_starts.items);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.append('\n');
        at_line_start = true;
        prev_token = null;
    }

    try emitTokens(&state, rest.items, source, line_starts.items);

    try alignTrailingComments(allocator, &out);

    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append('\n');
    }

    return std.mem.eql(u8, source, out.items);
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
/// Compiles `c_path` (a `fuzz`-mode harness, see `emit_fuzz_mode_harness`
/// in the transpiler) with the fixed flag a coverage-guided fuzzing
/// engine's own runtime needs, into `exe_file`.
///
/// Deliberately narrower than `invoke_c_compiler_to_exe`'s multi-candidate
/// fallback: only a compiler whose toolchain bundles that engine's
/// runtime can produce a WORKING binary here (a compiler that doesn't
/// support the flag at all would either reject it outright or silently
/// produce a binary that never actually calls into the fuzz target).
///
/// When `$FUN_FUZZ_CC` is set, it's trusted as-is (no fallback search) --
/// same "explicit override wins outright" convention as `FUN_CC` for
/// `invoke_c_compiler_to_exe`, but under its OWN name: a user's ordinary
/// `FUN_CC` (their normal build compiler -- gcc, cl, whatever) has
/// nothing to do with whether it can ALSO do coverage-guided fuzzing,
/// so reusing it here would silently skip the fallback search below in
/// favor of a compiler picked for an unrelated reason. Otherwise this
/// tries a short list of candidates most likely to actually have the
/// runtime:
/// plain `clang` first (works out of the box on many Linux distros'
/// packaged clang), then a couple of common non-default install
/// locations (Homebrew's LLVM on macOS, where the platform default --
/// Xcode's bundled clang -- does NOT include this runtime; versioned
/// `clang-N` binaries on Linux, where the unversioned `clang` symlink
/// isn't always installed even when a versioned one is; the official
/// LLVM installer's default path on Windows). Fails with a clear,
/// actionable message (not a silent no-op) when nothing in the list
/// works.
///
/// Windows note: this has NOT been tested on Windows at all (no Windows
/// machine available while building it) -- plain LLVM `clang.exe`
/// SHOULD accept the same flags used here unmodified (it's the same
/// GNU-style driver as macOS/Linux clang, distinct from `clang-cl.exe`'s
/// MSVC-flag-compatible one, which isn't tried), but whether the
/// coverage-guided runtime itself is reliably bundled with Windows LLVM
/// builds, and whether the resulting binary actually runs correctly,
/// is genuinely unverified. Treat Windows fuzzing as "might work," not
/// a confirmed-working platform, until someone actually tries it.
fn fuzz_compiler_candidates(allocator: mem.Allocator) ![][]const u8 {
    var list = ArrayList([]const u8).init(allocator);
    errdefer free_arg_list(allocator, list.items);
    try list.append(try allocator.dupe(u8, "clang"));
    if (builtin.target.os.tag == .macos) {
        try list.append(try allocator.dupe(u8, "/opt/homebrew/opt/llvm/bin/clang"));
        try list.append(try allocator.dupe(u8, "/usr/local/opt/llvm/bin/clang"));
    } else if (builtin.target.os.tag == .linux) {
        const versions = [_][]const u8{ "clang-20", "clang-19", "clang-18", "clang-17", "clang-16", "clang-15", "clang-14" };
        for (versions) |v| try list.append(try allocator.dupe(u8, v));
    } else if (builtin.target.os.tag == .windows) {
        // The official LLVM Windows installer's default install path, in
        // case `clang.exe` (plain LLVM clang, NOT `clang-cl.exe` -- the
        // MSVC-flag-compatible driver, which this doesn't try at all,
        // see the doc comment above) isn't already on PATH.
        try list.append(try allocator.dupe(u8, "C:\\Program Files\\LLVM\\bin\\clang.exe"));
    }
    return list.toOwnedSlice();
}

fn invoke_fuzz_compiler_to_exe(allocator: mem.Allocator, io: std.Io, c_path: []const u8, exe_file: []const u8, debug_info: bool) !void {
    // Deliberately `FUN_FUZZ_CC`, NOT the general `FUN_CC` -- a user may
    // already have `FUN_CC` set globally for their ORDINARY builds (gcc,
    // cl, whatever they normally use), which has nothing to do with
    // whether it can do coverage-guided fuzzing at all. Reusing `FUN_CC`
    // here would silently skip the whole fallback candidate search
    // (below) in favor of a compiler picked for an unrelated reason,
    // exactly the trap this hit during development: `FUN_CC=gcc` set in
    // the shell for normal use caused `fun fuzz` to try gcc specifically
    // and fail, even though the fallback list would have found a working
    // compiler immediately.
    var owned_cc: ?[]const u8 = null;
    defer if (owned_cc) |v| allocator.free(v);
    if (std.c.getenv("FUN_FUZZ_CC")) |z| {
        const s = std.mem.sliceTo(z, 0);
        if (s.len > 0) owned_cc = try allocator.dupe(u8, s);
    }

    // Coverage-guided-only by default (`-fsanitize=fuzzer`) plus memory-error
    // detection (`,address`) for stronger bug-finding -- but AddressSanitizer's
    // own startup (its shadow-memory mmap setup) has been observed to hang
    // indefinitely under some restricted/sandboxed/containerized environments
    // even when the compiler and fuzzing engine both work fine otherwise.
    // `FUN_FUZZ_NO_ASAN=1` drops just the `,address` half for exactly that
    // case -- fuzzing still runs and finds crashes/failed asserts, just
    // without ASan's additional memory-safety detection.
    const sanitize_flag = blk: {
        if (std.c.getenv("FUN_FUZZ_NO_ASAN")) |z| {
            const s = std.mem.sliceTo(z, 0);
            if (s.len > 0 and !std.mem.eql(u8, s, "0")) break :blk "-fsanitize=fuzzer";
        }
        break :blk "-fsanitize=fuzzer,address";
    };

    const candidates: [][]const u8 = if (owned_cc) |cc|
        try allocator.dupe([]const u8, &.{cc})
    else
        try fuzz_compiler_candidates(allocator);
    defer if (owned_cc == null) free_arg_list(allocator, candidates) else allocator.free(candidates);

    var last_stderr: []const u8 = "";
    defer if (last_stderr.len > 0) allocator.free(last_stderr);
    var any_compiler_found = false;

    for (candidates) |cc| {
        var argv_list = ArrayList([]const u8).init(allocator);
        defer argv_list.deinit();
        defer free_arg_list(allocator, argv_list.items);

        try argv_list.append(try allocator.dupe(u8, cc));
        try argv_list.append(try allocator.dupe(u8, sanitize_flag));
        try argv_list.append(try allocator.dupe(u8, if (debug_info) "-g" else "-g0"));
        try argv_list.append(try allocator.dupe(u8, c_path));
        try argv_list.append(try allocator.dupe(u8, "-o"));
        try argv_list.append(try allocator.dupe(u8, exe_file));
        if (builtin.target.os.tag != .windows) {
            try argv_list.append(try allocator.dupe(u8, "-pthread"));
            try argv_list.append(try allocator.dupe(u8, "-lm"));
        }

        const result = std.process.run(allocator, io, .{
            .argv = argv_list.items,
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        any_compiler_found = true;

        if (result.term.exited == 0) {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return;
        }

        allocator.free(result.stdout);
        if (last_stderr.len > 0) allocator.free(last_stderr);
        last_stderr = result.stderr;
        // Try the next candidate (an explicit $FUN_FUZZ_CC never falls
        // through -- `candidates` only ever has one entry in that case).
    }

    if (!any_compiler_found) return CliError.MissingCCompiler;

    // Deliberately-broken-C tests (exercising the CompilationFailed path
    // itself) would otherwise dump a real-looking "Compilation error:"
    // block into every test run/CI log even though the test is passing --
    // real CLI usage still needs to see this, so only test mode is muted.
    if (!builtin.is_test) {
        std.Io.File.stderr().writeStreamingAll(io, "Compilation error:\n") catch {};
        std.Io.File.stderr().writeStreamingAll(io, last_stderr) catch {};
        std.Io.File.stderr().writeStreamingAll(io,
            \\
            \\Note: fuzzing needs a compiler whose toolchain bundles a
            \\coverage-guided fuzzing runtime (commonly available with a
            \\mainline install; not always bundled with a platform's default
            \\one). Set FUN_FUZZ_CC to point at a compiler that has it if none
            \\of the ones tried automatically worked -- this is separate from
            \\FUN_CC (your ordinary build compiler), since they may need to be
            \\different compilers entirely. If it compiles but then hangs
            \\immediately on running, try FUN_FUZZ_NO_ASAN=1 -- some
            \\restricted/sandboxed environments hang during AddressSanitizer's
            \\own startup.
            \\
        ) catch {};
        if (builtin.target.os.tag == .windows) {
            std.Io.File.stderr().writeStreamingAll(io,
                \\
                \\Windows note: fuzzing is unverified on Windows -- try
                \\installing plain LLVM `clang.exe` (not clang-cl) and pointing
                \\FUN_FUZZ_CC at it if it isn't already found automatically.
                \\
            ) catch {};
        }
    }
    return CliError.CompilationFailed;
}

/// Invokes a C compiler on `c_path`, producing `exe_file`. Honors
/// `FUN_CC`/`FUN_CC_ARGS` env var overrides, falling back to a list of
/// default compiler candidates (see `get_default_compiler_candidates`).
/// Shared by `compile_and_run` (compile + run + delete) and `compile_to_exe`
/// (compile + keep, used by `fun build`) -- callers decide what happens to
/// the resulting binary; this only handles getting it built.
fn invoke_c_compiler_to_exe(allocator: mem.Allocator, io: std.Io, c_path: []const u8, exe_file: []const u8, debug_info: bool) !void {
    var fun_cc: ?[]const u8 = null;
    var fun_cc_args: ?[]const u8 = null;
    if (std.c.getenv("FUN_CC")) |z| {
        const s = std.mem.sliceTo(z, 0);
        if (s.len > 0) fun_cc = try allocator.dupe(u8, s);
    }
    defer if (fun_cc) |v| allocator.free(v);

    if (std.c.getenv("FUN_CC_ARGS")) |z| {
        const s = std.mem.sliceTo(z, 0);
        if (s.len > 0) fun_cc_args = try allocator.dupe(u8, s);
    }
    defer if (fun_cc_args) |v| allocator.free(v);

    if (fun_cc != null and fun_cc.?.len > 0) {
        var argv_list = ArrayList([]const u8).init(allocator);
        defer argv_list.deinit();
        defer free_arg_list(allocator, argv_list.items);
        var used_template = false;
        var non_template_base_argc: usize = 0;

        var base = try parse_command_line(allocator, fun_cc.?);
        defer base.deinit();
        defer free_arg_list(allocator, base.items);

        const uses_template = std.mem.indexOf(u8, fun_cc.?, "{src}") != null or std.mem.indexOf(u8, fun_cc.?, "{out}") != null;
        used_template = uses_template;
        if (uses_template) {
            for (base.items) |a| {
                const replaced = try replace_placeholders(allocator, a, c_path, exe_file);
                try argv_list.append(replaced);
            }
        } else {
            for (base.items) |a| {
                try argv_list.append(try allocator.dupe(u8, a));
            }
            non_template_base_argc = base.items.len;
            const flavor = if (argv_list.items.len >= 1) detect_compiler_flavor(argv_list.items[0]) else .unknown;
            try append_default_compile_args(allocator, &argv_list, flavor, c_path, exe_file, debug_info);
        }

        var using_zig = false;
        if (argv_list.items.len >= 1) {
            const cc_base = std.fs.path.basename(argv_list.items[0]);
            if (std.mem.eql(u8, cc_base, "zig") or std.mem.eql(u8, cc_base, "zig.exe")) {
                using_zig = true;
            }
        }

        if (fun_cc_args != null and fun_cc_args.?.len > 0) {
            var extra = try parse_command_line(allocator, fun_cc_args.?);
            defer extra.deinit();
            defer free_arg_list(allocator, extra.items);
            try append_fun_cc_extra_args(allocator, &argv_list, extra.items, using_zig, used_template, non_template_base_argc);
        }

        const result = std.process.run(allocator, io, .{
            .argv = argv_list.items,
        }) catch |err| switch (err) {
            error.FileNotFound => return CliError.MissingCCompiler,
            else => return err,
        };
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        if (result.term.exited != 0) {
            // See the matching comment in the fuzz-compiler fallback below --
            // muted in test mode so a deliberately-broken-C negative test
            // doesn't dump a real-looking compiler error into CI logs.
            if (!builtin.is_test) {
                std.Io.File.stderr().writeStreamingAll(io, "Compilation error:\n") catch {};
                // cl.exe sends errors to stdout; gcc/clang send them to stderr.
                // Print both so no output is lost regardless of compiler.
                std.Io.File.stderr().writeStreamingAll(io, result.stdout) catch {};
                std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
            }
            return CliError.CompilationFailed;
        }
    } else {
        const candidates = get_default_compiler_candidates();
        var any_compiler_found = false;

        for (candidates) |candidate| {
            var argv_list = ArrayList([]const u8).init(allocator);
            defer argv_list.deinit();
            defer free_arg_list(allocator, argv_list.items);

            try argv_list.append(try allocator.dupe(u8, candidate.cmd));
            for (candidate.extra) |a| {
                try argv_list.append(try allocator.dupe(u8, a));
            }
            try append_default_compile_args(allocator, &argv_list, candidate.flavor, c_path, exe_file, debug_info);

            const result = std.process.run(allocator, io, .{
                .argv = argv_list.items,
            }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }

            any_compiler_found = true;
            if (result.term.exited != 0) {
                if (!builtin.is_test) {
                    std.Io.File.stderr().writeStreamingAll(io, "Compilation error:\n") catch {};
                    std.Io.File.stderr().writeStreamingAll(io, result.stdout) catch {};
                    std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
                }
                return CliError.CompilationFailed;
            }

            break;
        }

        if (!any_compiler_found) return CliError.MissingCCompiler;
    }
}

pub fn compile_and_run(allocator: mem.Allocator, io: std.Io, c_file_or_content: []const u8, is_file: bool, input_file: []const u8, program_args: []const []const u8, debug_info: bool, fuzz_mode: bool) !void {
    return compile_and_run_ex(allocator, io, c_file_or_content, is_file, input_file, program_args, debug_info, fuzz_mode, true);
}

/// Same as `compile_and_run`, but with control over how a nonzero exit from
/// the compiled program is reported. `exit_process_on_nonzero = true`
/// matches `compile_and_run` (calls `std.process.exit`, preserving the exit
/// code for shell scripts -- the right behavior for a single `fun -in
/// file.fn` invocation). A caller running many files in one process (e.g.
/// the `fun test`/`fun fuzz` directory runner) passes `false` instead, so a
/// failing file returns `CliError.ExecutionFailed` to its own caller rather
/// than ending the whole process before the rest of the suite runs.
pub fn compile_and_run_ex(allocator: mem.Allocator, io: std.Io, c_file_or_content: []const u8, is_file: bool, input_file: []const u8, program_args: []const []const u8, debug_info: bool, fuzz_mode: bool, exit_process_on_nonzero: bool) !void {
    const input_path = std.fs.path.basename(input_file);
    const extension_index = std.mem.lastIndexOf(u8, input_path, ".");
    var exe_file_name: []const u8 = input_path;
    if (extension_index) |index| {
        exe_file_name = input_path[0..index];
    }

    // Multiple runs can collide on the same output exe/pdb name, and on Windows
    // that can lead to file-lock stalls. Make the output name unique.
    const exe_file_name_owned = blk: {
        const S = struct {
            var uid: std.atomic.Value(u64) = .init(0);
        };
        break :blk try std.fmt.allocPrint(allocator, "{s}_{d}", .{ exe_file_name, S.uid.fetchAdd(1, .monotonic) });
    };
    defer allocator.free(exe_file_name_owned);
    exe_file_name = exe_file_name_owned;
    const exe_file = blk: {
        if (builtin.target.os.tag == .windows) {
            break :blk try std.fmt.allocPrint(allocator, "{s}.exe", .{exe_file_name});
        }
        break :blk try allocator.dupe(u8, exe_file_name);
    };
    defer allocator.free(exe_file);
    // Always attempt cleanup even on early returns.
    defer std.Io.Dir.cwd().deleteFile(io, exe_file) catch {};

    const pdb_file: ?[]const u8 = if (builtin.target.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "{s}.pdb", .{exe_file_name})
    else
        null;
    defer if (pdb_file) |p| allocator.free(p);
    defer if (pdb_file) |p| {
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
    };

    // If content is provided instead of a file, write it to a temporary file first
    var c_path: []const u8 = undefined;
    var temp_name: ?[]const u8 = null;
    if (!is_file) {
        const S = struct {
            var uid: std.atomic.Value(u64) = .init(0);
        };
        temp_name = try std.fmt.allocPrint(allocator, "temp_{d}.c", .{S.uid.fetchAdd(1, .monotonic)});
        errdefer if (temp_name) |name| allocator.free(name);

        const temp_file = try std.Io.Dir.cwd().createFile(io, temp_name.?, .{});
        try temp_file.writeStreamingAll(io, c_file_or_content);
        temp_file.close(io);

        c_path = temp_name.?;
    } else {
        c_path = c_file_or_content;
    }

    // Make sure to clean up temp file in all cases when it's not a permanent file
    defer if (!is_file and temp_name != null) {
        std.Io.Dir.cwd().deleteFile(io, temp_name.?) catch {};
        allocator.free(temp_name.?);
    };

    if (fuzz_mode) {
        try invoke_fuzz_compiler_to_exe(allocator, io, c_path, exe_file, debug_info);
    } else {
        try invoke_c_compiler_to_exe(allocator, io, c_path, exe_file, debug_info);
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

        // Build argv: exe + forwarded args.
        var argv_all = try allocator.alloc([]const u8, 1 + program_args.len);
        defer allocator.free(argv_all);
        argv_all[0] = exe_file_for_os;
        for (program_args, 0..) |a, i| argv_all[i + 1] = a;

        if (builtin.is_test) {
            const result = try std.process.run(allocator, io, .{
                .argv = argv_all,
            });
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }

            switch (result.term) {
                .exited => |code| if (code != 0) return CliError.ExecutionFailed,
                else => return CliError.ExecutionFailed,
            }
        } else {
            // In normal CLI usage we want the compiled program to behave like a normal
            // executable: inherit stdin/stdout/stderr so interactive programs work.
            var child = try std.process.spawn(io, .{
                .argv = argv_all,
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            const term = try child.wait(io);
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        if (!exit_process_on_nonzero) return CliError.ExecutionFailed;
                        // Preserve program exit status for callers/shell scripts.
                        std.process.exit(code);
                    }
                },
                else => return CliError.ExecutionFailed,
            }
        }
    }

    // Executable cleanup handled via defer above.
}

/// Compiles a `.c` file to a binary at `exe_output_path` and KEEPS it (does
/// not run it, does not delete it) -- used by `fun build`, unlike
/// `compile_and_run` (which always runs the binary once and deletes it
/// afterward). `exe_output_path` is used verbatim as the compiler's `-o`
/// target, so the caller decides the final name/location (already resolved,
/// including the platform's `.exe` suffix on Windows).
pub fn compile_to_exe(allocator: mem.Allocator, io: std.Io, c_path: []const u8, exe_output_path: []const u8, debug_info: bool) !void {
    try invoke_c_compiler_to_exe(allocator, io, c_path, exe_output_path, debug_info);
}

/// `fun build`: reads `./fun.toml`, compiles each declared `[[bin]]` target,
/// and installs the resulting binaries under `fun-out/bin/`. Unlike a plain
/// `fun -in file.fn`, nothing is run afterward -- matching `zig build`
/// (compile only; `zig build run`/`fun -in ... ` are the "compile and run"
/// paths). Fun's own `imp` already does path-based module resolution, so
/// the manifest only needs to declare build TARGETS, not an import graph.
pub fn run_build(allocator: mem.Allocator, io: std.Io, debug_info: bool) !void {
    return run_build_in(allocator, io, ".", debug_info);
}

/// Builds the manifest in `root` rather than the working directory. Every path
/// the build reads or writes -- the manifest, each target's source, the
/// generated C, and the installed executable -- is resolved against `root`, so
/// a build never depends on where it was started from.
pub fn run_build_in(allocator: mem.Allocator, io: std.Io, root: []const u8, debug_info: bool) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "fun.toml" });
    defer allocator.free(manifest_path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return CliError.ManifestNotFound,
        else => return err,
    };
    defer allocator.free(text);

    var m = try manifest.parse(allocator, text);
    defer m.deinit();

    const bin_dir = try std.fs.path.join(allocator, &.{ root, "fun-out", "bin" });
    defer allocator.free(bin_dir);
    try std.Io.Dir.cwd().createDirPath(io, bin_dir);

    for (m.bins) |b| {
        const out_c_name = try std.fmt.allocPrint(allocator, "{s}.fun-build.c", .{b.name});
        defer allocator.free(out_c_name);
        const out_c_path = try std.fs.path.join(allocator, &.{ root, out_c_name });
        defer allocator.free(out_c_path);
        defer std.Io.Dir.cwd().deleteFile(io, out_c_path) catch {};

        const src_path = try std.fs.path.join(allocator, &.{ root, b.path });
        defer allocator.free(src_path);

        // A target can reference `PACKAGE_NAME`/`PACKAGE_VERSION` as
        // ordinary top-level consts, taken from this manifest, without
        // declaring them itself. Implemented at the source-text level --
        // prepended ahead of the real file's own text, into a sibling
        // temp file in the same directory so the target's own relative
        // imports keep resolving -- rather than as an AST-level
        // injection, since this compiler otherwise never synthesizes AST
        // nodes outside of parsing real source.
        const original_text = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(original_text);
        const prelude = try std.fmt.allocPrint(
            allocator,
            "pub const str PACKAGE_NAME = \"{s}\";\npub const str PACKAGE_VERSION = \"{s}\";\n",
            .{ m.package_name, m.version },
        );
        defer allocator.free(prelude);
        const injected_text = try std.mem.concat(allocator, u8, &.{ prelude, original_text });
        defer allocator.free(injected_text);

        const src_dir = std.fs.path.dirname(src_path) orelse ".";
        const tmp_leaf = try std.fmt.allocPrint(allocator, ".{s}.fun-build-defines.fn", .{b.name});
        defer allocator.free(tmp_leaf);
        const tmp_path = try std.fs.path.join(allocator, &.{ src_dir, tmp_leaf });
        defer allocator.free(tmp_path);
        defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

        {
            const tmp_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            try tmp_file.writeStreamingAll(io, injected_text);
            tmp_file.close(io);
        }

        {
            var tp = try codegen.TranspileProcess.init(allocator, tmp_path, out_c_path, .{
                .exec = false,
                .outf = true,
                .debug_info = debug_info,
            });
            var lp = lexer.LexProcess.init(&tp);
            var pp = parser.ParseProcess.init(&tp);
            defer {
                lp.deinit();
                tp.deinit();
            }
            try lp.lex();
            try pp.parse();
            try tp.transpile();
        }
        // tp/lp are fully deinited (output file handle released) before
        // invoking the C compiler, which needs to open the same file.

        const exe_leaf = if (builtin.target.os.tag == .windows)
            try std.fmt.allocPrint(allocator, "{s}.exe", .{b.name})
        else
            try allocator.dupe(u8, b.name);
        defer allocator.free(exe_leaf);
        const exe_name = try std.fs.path.join(allocator, &.{ bin_dir, exe_leaf });
        defer allocator.free(exe_name);

        try compile_to_exe(allocator, io, out_c_path, exe_name, debug_info);

        // Only print progress OUTSIDE of tests: under `zig build test`, this
        // process's real stdout carries the `--listen=-` build-protocol
        // stream, not plain text -- writing raw text into it stalls the
        // build runner waiting on a well-formed protocol frame that never
        // arrives (same reason `compile_and_run`'s "run the program" step
        // branches on `builtin.is_test` instead of inheriting stdio there).
        if (!builtin.is_test) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "built {s} -> {s}\n", .{ b.name, exe_name }) catch "built\n";
            std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
        }
    }
}
