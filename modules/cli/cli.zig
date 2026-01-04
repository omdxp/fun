const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const process = std.process;
const Child = std.process.Child;
const codegen = @import("codegen");
const lexer = @import("lexer");
const token = lexer.token;
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

    /// Flag to format the input `.fn` file in-place.
    fmt: bool,

    /// Flag to format the input file and all locally imported modules (skips `std.*`).
    fmt_all: bool,

    /// Arguments passed to the compiled program (everything after `--`).
    program_args: [][]const u8,
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
        \\Usage:
        \\  fun -in <input_file> [-fmt | -fmt-all] [-out <output_file>] [-no-exec] [-outf] [-ast] [-help] [-- <program args...>]
        \\  fun -version
        \\
        \\Arguments:
        \\  -help             Show this help message
        \\  -version          Print version and exit
        \\  -in      <file>   Input file to compile (required)
        \\  -fmt              Format the input file in-place (optional)
        \\  -fmt-all          Format the input file and all locally imported modules (optional)
        \\  -out     <file>   Output file (optional, defaults to input filename with .c extension)
        \\  -no-exec          Disable automatic compilation and execution (optional, execution enabled by default)
        \\  -outf             Generate .c output file (optional, disabled by default)
        \\  -ast              Print AST nodes (optional, disabled by default)
        \\  --                All following args are passed to the compiled program
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
    var fmt = false;
    var fmt_all = false;
    var program_args = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (program_args.items) |p| allocator.free(p);
        program_args.deinit();
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |p| {
                try program_args.append(try allocator.dupe(u8, p));
            }
            break;
        }
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
        } else if (std.mem.eql(u8, arg, "-fmt")) {
            fmt = true;
        } else if (std.mem.eql(u8, arg, "-fmt-all")) {
            fmt_all = true;
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
        .fmt = fmt,
        .fmt_all = fmt_all,
        .program_args = try program_args.toOwnedSlice(),
    };
}

fn build_full_import_path_for_formatter(allocator: mem.Allocator, input_file_path: []const u8, import_path: []const u8) ![]const u8 {
    var file_path = std.ArrayList(u8).init(allocator);
    defer file_path.deinit();

    const dir_path = std.fs.path.dirname(input_file_path) orelse ".";
    try file_path.appendSlice(dir_path);
    try file_path.append('/');

    for (import_path) |ch| {
        if (ch == '.') {
            try file_path.append('/');
        } else {
            try file_path.append(ch);
        }
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

fn parse_local_import_paths(allocator: mem.Allocator, input_file: []const u8) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);
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
            if (j >= tokens.len or tokens[j].type != .Identifier) {
                // Let the normal compiler path handle detailed errors; formatter just ignores malformed imports.
                continue;
            }

            var import_name = std.ArrayList(u8).init(allocator);
            defer import_name.deinit();
            try import_name.appendSlice(tokens[j].data.sval.items);
            j += 1;

            while (true) {
                while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}
                if (j >= tokens.len) break;
                if (tokens[j].type != .Operator or !utils.is_access_operator(tokens[j].data.sval.items)) break;
                j += 1;

                while (j < tokens.len and (tokens[j].type == .NewLine or tokens[j].type == .Comment)) : (j += 1) {}
                if (j >= tokens.len or tokens[j].type != .Identifier) break;
                try import_name.append('.');
                try import_name.appendSlice(tokens[j].data.sval.items);
                j += 1;
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
    file_path: []const u8,
    visiting: *std.StringHashMap(void),
    visited: *std.StringHashMap(void),
) !void {
    const canonical = try std.fs.cwd().realpathAlloc(allocator, file_path);
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
    try format_file_in_place(allocator, canonical);

    // Discover local imports and recurse.
    var imports = try parse_local_import_paths(allocator, canonical);
    defer {
        for (imports.items) |p| allocator.free(p);
        imports.deinit();
    }

    for (imports.items) |imp| {
        const rel = try build_full_import_path_for_formatter(allocator, canonical, imp);
        defer allocator.free(rel);
        try format_file_and_imports_recursive(allocator, rel, visiting, visited);
    }

    // Move from visiting -> visited.
    _ = visiting.remove(canonical);
    try visited.put(canonical, {});
}

pub fn format_file_and_imports_in_place(allocator: mem.Allocator, input_file: []const u8) !void {
    var visiting = std.StringHashMap(void).init(allocator);
    defer freeOwnedStringMap(allocator, &visiting);

    var visited = std.StringHashMap(void).init(allocator);
    defer freeOwnedStringMap(allocator, &visited);

    try format_file_and_imports_recursive(allocator, input_file, &visiting, &visited);
}

fn token_text(allocator: mem.Allocator, t: token.Token) ![]const u8 {
    return switch (t.type) {
        .Identifier, .Keyword, .Operator => allocator.dupe(u8, t.data.sval.items),
        .Symbol => blk: {
            var buf: [1]u8 = .{t.data.cval};
            break :blk allocator.dupe(u8, buf[0..]);
        },
        .Number => {
            // Note: char literals are currently tokenized as Number with `cval`.
            if (t.data == .cval) {
                const c = t.data.cval;
                var out = std.ArrayList(u8).init(allocator);
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
                .dnum => blk: {
                    // Fun doesn't support scientific notation (e.g. `3.14159e0`).
                    // Use a decimal formatter that never emits exponent notation.
                    var buf = std.ArrayList(u8).init(allocator);
                    errdefer buf.deinit();
                    try std.fmt.format(buf.writer(), "{d}", .{t.data.dnum});
                    break :blk try buf.toOwnedSlice();
                },
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
        .String => std.fmt.allocPrint(allocator, "\"{s}\"", .{t.data.sval.items}),
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
    return !std.mem.eql(u8, op, ",") and
        !std.mem.eql(u8, op, ".") and
        !std.mem.eql(u8, op, "(") and
        !std.mem.eql(u8, op, "[");
}

fn is_builtin_type_keyword(kw: []const u8) bool {
    return std.mem.eql(u8, kw, "void") or
        std.mem.eql(u8, kw, "raw") or
        std.mem.eql(u8, kw, "num") or
        std.mem.eql(u8, kw, "dec") or
        std.mem.eql(u8, kw, "str") or
        std.mem.eql(u8, kw, "bin") or
        std.mem.eql(u8, kw, "chr");
}

fn isLikelyTypeToken(t: token.Token) bool {
    return switch (t.type) {
        .Keyword => is_builtin_type_keyword(t.data.sval.items),
        .Identifier => t.data.sval.items.len > 0 and (t.data.sval.items[0] >= 'A' and t.data.sval.items[0] <= 'Z'),
        else => false,
    };
}

fn nextSignificantToken(toks: []const token.Token, start_at: usize) ?token.Token {
    var i: usize = start_at;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return t;
    }
    return null;
}

fn isPointerTypeStarContext(toks: []const token.Token, idx: usize, prev: token.Token) bool {
    if (!isLikelyTypeToken(prev)) return false;

    const next = nextSignificantToken(toks, idx + 1) orelse return false;
    // Return type pointers: `...) Type* {` or `...) Type*;`
    if (next.type == .Symbol and (next.data.cval == '{' or next.data.cval == ';')) return true;

    // Declaration/field/param pointers: `Type* name` (name then delimiter)
    if (next.type == .Identifier) {
        const after_name = nextSignificantToken(toks, idx + 2) orelse return false;
        if (after_name.type == .Symbol and (after_name.data.cval == ';' or after_name.data.cval == ',' or after_name.data.cval == ')' or after_name.data.cval == ']')) return true;
        if (after_name.type == .Operator and (std.mem.eql(u8, after_name.data.sval.items, "=") or std.mem.eql(u8, after_name.data.sval.items, ","))) return true;
    }
    return false;
}

fn appendAll(dst: *std.ArrayList(token.Token), src: []const token.Token) !void {
    for (src) |t| {
        try dst.append(t);
    }
}

const EmitState = struct {
    indent: *usize,
    at_line_start: *bool,
    prev_token: *?token.Token,
    out: *std.ArrayList(u8),
    allocator: mem.Allocator,
};

const fmt_indent_width: usize = 2;

fn ensureBlankLine(out: *std.ArrayList(u8)) !void {
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
        std.mem.eql(u8, kw, "impl");
}

fn emitTokens(state: *EmitState, toks: []const token.Token) !void {
    var idx: usize = 0;
    var pending_newlines: usize = 0;
    var cond_paren_depth: usize = 0;
    var skipping_cond_outer_parens: bool = false;
    var wrap_cond_open_at: ?usize = null;
    var wrap_cond_close_before: ?usize = null;
    var prev_unary_prefix: bool = false;
    while (idx < toks.len) : (idx += 1) {
        const t2 = toks[idx];
        if (t2.type == .NewLine) {
            pending_newlines += 1;
            continue;
        }

        // Preserve blank lines (2+ newlines) between statements/constructs.
        if (pending_newlines >= 2) {
            if (!state.at_line_start.*) {
                try state.out.append('\n');
                state.at_line_start.* = true;
            }
            try ensureBlankLine(state.out);
            state.at_line_start.* = true;
            state.prev_token.* = null;
        }
        pending_newlines = 0;

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
            if (!state.at_line_start.*) {
                try state.out.append('\n');
                state.at_line_start.* = true;
            }
            if (state.at_line_start.*) {
                try state.out.appendNTimes(' ', state.indent.* * fmt_indent_width);
            }
            const s2 = try token_text(state.allocator, t2);
            defer state.allocator.free(s2);
            try state.out.appendSlice(s2);
            try state.out.append('\n');
            state.at_line_start.* = true;
            state.prev_token.* = null;
            continue;
        }

        if (t2.type == .Keyword) {
            const kw2 = t2.data.sval.items;
            if (std.mem.eql(u8, kw2, "if") or std.mem.eql(u8, kw2, "elif")) {
                // Decide whether this `if/elif` is a block (`{}`) or a single-statement form.
                // If it's a block and the condition is parenthesized, we strip the outer parens.
                // If it's single-statement and the condition is NOT parenthesized, we add parens.
                var jcond: usize = idx + 1;
                while (jcond < toks.len and (toks[jcond].type == .NewLine or toks[jcond].type == .Comment)) : (jcond += 1) {}
                if (jcond < toks.len) {
                    const cond_has_parens = toks[jcond].type == .Operator and std.mem.eql(u8, toks[jcond].data.sval.items, "(");

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

                    if (is_block and cond_has_parens) {
                        skipping_cond_outer_parens = true;
                        cond_paren_depth = 0;
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
        }

        // Handle closing brace with optional same-line `elif`/`else`.
        if (t2.type == .Symbol and t2.data.cval == '}') {
            if (!state.at_line_start.*) {
                try state.out.append('\n');
                state.at_line_start.* = true;
            }
            if (state.indent.* > 0) state.indent.* -= 1;
            try state.out.appendNTimes(' ', state.indent.* * fmt_indent_width);
            try state.out.append('}');

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

        // Decide whether to add a space before this token.
        if (state.prev_token.*) |pt2| {
            const needs_space = blk: {
                if (prev_unary_prefix) {
                    // Keep unary prefix operators glued to their operand: `-w`, `-1`, `+(x)`.
                    prev_unary_prefix = false;
                    break :blk false;
                }
                if (t2.type == .Operator and std.mem.eql(u8, t2.data.sval.items, "*") and isPointerTypeStarContext(toks, idx, pt2)) {
                    // Pointer types: `Type* name` / `Type* {`.
                    break :blk false;
                }
                if (pt2.type == .Keyword) {
                    const pkw2 = pt2.data.sval.items;
                    if (std.mem.eql(u8, pkw2, "if") or std.mem.eql(u8, pkw2, "elif")) {
                        // Always separate the keyword from the start of its condition, even if
                        // the condition starts with an inner grouping `(`.
                        break :blk true;
                    }
                }
                if (t2.type == .Symbol) {
                    const c2 = t2.data.cval;
                    if (c2 == ',' or c2 == ';' or c2 == ')' or c2 == ']' or c2 == '}' or c2 == ':') break :blk false;
                    if (c2 == '{') break :blk true;
                    if (c2 == '(' or c2 == '[') {
                        // No space for calls/indexing: `foo(`, `arr[`.
                        break :blk false;
                    }
                }
                if (pt2.type == .Symbol) {
                    const pc2 = pt2.data.cval;
                    if (pc2 == '(' or pc2 == '[' or pc2 == '{') break :blk false;
                }
                if (t2.type == .Operator and (std.mem.eql(u8, t2.data.sval.items, "(") or std.mem.eql(u8, t2.data.sval.items, "["))) {
                    // Distinguish grouping after spaced operators (e.g. `|| (`) from calls/indexing (e.g. `foo(`).
                    if (pt2.type == .Operator and operator_needs_spaces(pt2.data.sval.items)) break :blk true;
                    break :blk false;
                }
                if (t2.type == .Operator) {
                    break :blk operator_needs_spaces(t2.data.sval.items);
                }
                if (pt2.type == .Operator) {
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
                try state.out.append('{');
                try state.out.append('\n');
                state.indent.* += 1;
                state.at_line_start.* = true;
                state.prev_token.* = null;
                continue;
            }
            if (c2 == ';') {
                try state.out.append(';');
                try state.out.append('\n');
                state.at_line_start.* = true;
                state.prev_token.* = null;
                continue;
            }
            if (c2 == ',') {
                try state.out.append(',');
                try state.out.append(' ');
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
            try state.out.append(' ');
            state.prev_token.* = null;
            continue;
        }

        if (t2.type == .Operator and (std.mem.eql(u8, t2.data.sval.items, "(") or std.mem.eql(u8, t2.data.sval.items, "["))) {
            const s2 = try token_text(state.allocator, t2);
            defer state.allocator.free(s2);
            try state.out.appendSlice(s2);
            state.prev_token.* = t2;
            continue;
        }

        const s2 = try token_text(state.allocator, t2);
        defer state.allocator.free(s2);
        try state.out.appendSlice(s2);

        // Track unary prefix ops so we don't insert a space after them.
        if (t2.type == .Operator) {
            const op2 = t2.data.sval.items;
            if ((std.mem.eql(u8, op2, "-") or std.mem.eql(u8, op2, "+") or std.mem.eql(u8, op2, "&") or std.mem.eql(u8, op2, "*"))) {
                const unary_ctx = blk: {
                    const prev = state.prev_token.*;
                    if (prev == null) break :blk true;
                    const pt = prev.?;
                    if (pt.type == .Keyword) {
                        const kw = pt.data.sval.items;
                        // Keywords that are followed by an expression.
                        if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for")) break :blk true;
                    }
                    if (is_word_like(pt)) break :blk false;
                    if (pt.type == .Symbol and is_closing_symbol(pt.data.cval)) break :blk false;
                    break :blk true;
                };
                if (unary_ctx) prev_unary_prefix = true;
            }
        }
        state.prev_token.* = t2;
    }
}

pub fn format_file_in_place(allocator: mem.Allocator, input_file: []const u8) !void {
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

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var indent: usize = 0;
    var at_line_start = true;
    var prev_token: ?token.Token = null;

    const tokens = tp.tokens.items();

    // Partition top-level imports + global vars into groups.
    var imports = std.ArrayList(token.Token).init(allocator);
    defer imports.deinit();
    var globals = std.ArrayList(token.Token).init(allocator);
    defer globals.deinit();
    var rest = std.ArrayList(token.Token).init(allocator);
    defer rest.deinit();
    var pending_comments = std.ArrayList(token.Token).init(allocator);
    defer pending_comments.deinit();

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
        const starts_global_stmt = is_stmt_start and is_kw and is_builtin_type_keyword(kw);

        if (starts_import_stmt or starts_global_stmt) {
            // Collect up to ';'
            var stmt = std.ArrayList(token.Token).init(allocator);
            defer stmt.deinit();
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

    var state: EmitState = .{ .indent = &indent, .at_line_start = &at_line_start, .prev_token = &prev_token, .out = &out, .allocator = allocator };

    if (imports.items.len > 0) {
        try emitTokens(&state, imports.items);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.append('\n');
        at_line_start = true;
        prev_token = null;
    }

    if (globals.items.len > 0) {
        try emitTokens(&state, globals.items);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.append('\n');
        at_line_start = true;
        prev_token = null;
    }

    try emitTokens(&state, rest.items);

    // Ensure exactly one trailing newline.
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append('\n');
    }

    // Overwrite input file in-place.
    try tp.ifile.seekTo(0);
    try tp.ifile.setEndPos(0);
    _ = try tp.ifile.writeAll(out.items);
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
pub fn compile_and_run(allocator: mem.Allocator, c_file_or_content: []const u8, is_file: bool, input_file: []const u8, program_args: []const []const u8) !void {
    const input_path = std.fs.path.basename(input_file);
    const extension_index = std.mem.lastIndexOf(u8, input_path, ".");
    var exe_file_name: []const u8 = input_path;
    if (extension_index) |index| {
        exe_file_name = input_path[0..index];
    }

    // Multiple runs can collide on the same output exe/pdb name, and on Windows
    // that can lead to file-lock stalls. Make the output name unique.
    const exe_file_name_owned = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ exe_file_name, std.time.nanoTimestamp() });
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
    // test runner protocol. Also, noisy test stderr makes it look like failures.
    // Keep tests quiet, but preserve normal CLI output.
    const stdout = if (builtin.is_test) std.io.null_writer else std.io.getStdOut().writer();
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
            if (!builtin.is_test) {
                try stderr.print("Compilation error:\n{s}", .{result.stderr});
            }
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

        // Build argv: exe + forwarded args.
        var argv_all = try allocator.alloc([]const u8, 1 + program_args.len);
        defer allocator.free(argv_all);
        argv_all[0] = exe_file_for_os;
        for (program_args, 0..) |a, i| argv_all[i + 1] = a;

        if (builtin.is_test) {
            const result = try process.Child.run(.{
                .allocator = allocator,
                .argv = argv_all,
            });
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }

            if (result.term.Exited != 0) {
                return CliError.ExecutionFailed;
            }

            try stdout.print("{s}", .{result.stdout});
        } else {
            // In normal CLI usage we want the compiled program to behave like a normal
            // executable: inherit stdin/stdout/stderr so interactive programs work.
            var child = process.Child.init(argv_all, allocator);
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            try child.spawn();
            const term = try child.wait();
            if (term.Exited != 0) {
                return CliError.ExecutionFailed;
            }
        }
    }

    // Executable cleanup handled via defer above.
}
