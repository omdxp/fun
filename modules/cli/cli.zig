const std = @import("std");
const mem = std.mem;
const process = std.process;
const codegen = @import("codegen");
const lexer = @import("lexer");
const token = lexer.token;
const utils = @import("utils");
const builtin = @import("builtin");

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
fn print_usage(io: std.Io) void {
    std.Io.File.stderr().writeStreamingAll(io,
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
            // Validate file extension
            if (!std.mem.endsWith(u8, file, ".fn")) {
                return CliError.InvalidInputExtension;
            }
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
    // Dot runs are treated like access operators and should be glued: `.`, `..`, `...`, etc.
    for (op) |ch| {
        if (ch != '.') break;
    } else {
        return false;
    }
    return !std.mem.eql(u8, op, ",") and
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

fn append_default_compile_args(allocator: mem.Allocator, argv_list: *ArrayList([]const u8), flavor: CompilerFlavor, c_path: []const u8, exe_file: []const u8) !void {
    switch (flavor) {
        .cl => {
            try argv_list.append(try allocator.dupe(u8, c_path));
            const out_flag = try std.fmt.allocPrint(allocator, "/Fe{s}", .{exe_file});
            try argv_list.append(out_flag);
        },
        else => {
            try argv_list.append(try allocator.dupe(u8, "-g0"));
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
    try append_default_compile_args(allocator, &argv_list, .zig, "test.c", "test.exe");

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
    try append_default_compile_args(allocator, &argv_list, .gcc_like, "test.c", "test.exe");

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
    try append_default_compile_args(allocator, &argv_list, .cl, "test.c", "test.exe");

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
    while (i >= 0) : (i -= 1) {
        const t = toks[@intCast(i)];
        if (t.type == .NewLine or t.type == .Comment) continue;
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
        if (std.mem.eql(u8, kw, "impl") or std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "fun") or std.mem.eql(u8, kw, "pub")) return true;
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
        std.mem.eql(u8, kw, "impl");
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
    var pending_decl_block_open: bool = false;
    var decl_block_depth: isize = 0;
    var pending_enum_block_open: bool = false;
    var enum_block_depth: isize = 0;
    var pending_control_block_open: bool = false;
    var function_body_depth: isize = 0;
    var generic_angle_depth: usize = 0;
    var asm_raw: ?AsmRawRange = null;
    var brace_stack = ArrayList(bool).init(state.allocator);
    defer brace_stack.deinit();
    while (idx < toks.len) : (idx += 1) {
        const t2 = toks[idx];
        if (t2.type == .NewLine) {
            pending_newlines += 1;
            continue;
        }

        // Preserve blank lines (2+ newlines) between statements/constructs.
        if (pending_newlines >= 2) {
            if (!state.at_line_start.*) try state.out.append('\n');
            try ensureBlankLine(state.out);
            state.at_line_start.* = true;
            state.prev_token.* = null;
        }
        pending_newlines = 0;

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
            if (!state.at_line_start.*) {
                try state.out.append('\n');
                state.at_line_start.* = true;
            }
            if (state.at_line_start.*) {
                try state.out.appendNTimes(' ', state.indent.* * fmt_indent_width);
            }
            const s2 = try token_text(state.allocator, t2, source, line_starts);
            defer state.allocator.free(s2);
            try state.out.appendSlice(s2);
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
            const is_block_close = if (brace_stack.items.len > 0) brace_stack.items[brace_stack.items.len - 1] else true;
            if (brace_stack.items.len > 0) _ = brace_stack.pop();

            if (!is_block_close) {
                try state.out.append('}');
                state.prev_token.* = t2;
                continue;
            }

            if (decl_block_depth > 0) decl_block_depth -= 1;
            if (enum_block_depth > 0) enum_block_depth -= 1;
            if (function_body_depth > 0) function_body_depth -= 1;
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

        const in_decl_only_ctx = in_fun_signature or (decl_block_depth > 0 and function_body_depth == 0);
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
            (pending_decl_block_open or pending_enum_block_open or in_fun_signature or pending_control_block_open or prev_sig_is_rparen or prev_sig_is_type_after_paren or paren_before_brace or prev_sig_is_arrow or prev_sig_is_comma or prev_sig_is_semicolon or prev_sig_is_lbrace);

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
                if (pt2.type == .Keyword and std.mem.eql(u8, pt2.data.sval.items, "ret")) {
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
                                if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for")) break :blk_unary true;
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
                            if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for")) break :blk_unary_sym true;
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
                    if (c2 == ',' or c2 == ';' or c2 == ')' or c2 == ']' or c2 == '}' or c2 == ':') break :blk false;
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
                if (is_block_brace) {
                    if (pending_decl_block_open) {
                        decl_block_depth += 1;
                        pending_decl_block_open = false;
                    }
                    if (pending_enum_block_open) {
                        enum_block_depth += 1;
                        pending_enum_block_open = false;
                    }
                    if (pending_control_block_open) pending_control_block_open = false;
                    if (in_fun_signature) {
                        in_fun_signature = false;
                        function_body_depth += 1;
                    } else if (function_body_depth == 0 and decl_block_depth > 0 and !pending_decl_block_open and !pending_enum_block_open and !pending_control_block_open and (prev_sig_is_rparen or prev_sig_is_type_after_paren or paren_before_brace)) {
                        function_body_depth = 1;
                    } else if (function_body_depth > 0) {
                        function_body_depth += 1;
                    }
                    try brace_stack.append(true);
                    try state.out.append('{');
                    try state.out.append('\n');
                    state.indent.* += 1;
                    state.at_line_start.* = true;
                    state.prev_token.* = null;
                    continue;
                }
                try brace_stack.append(false);
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
                try state.out.append('\n');
                state.at_line_start.* = true;
                state.prev_token.* = null;
                continue;
            }
            if (c2 == ',') {
                try state.out.append(',');
                if (enum_block_depth > 0) {
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
            if (enum_block_depth > 0) {
                try state.out.append('\n');
                state.at_line_start.* = true;
            } else {
                try state.out.append(' ');
            }
            state.prev_token.* = null;
            continue;
        }

        if (t2.type == .Operator and (std.mem.eql(u8, t2.data.sval.items, "(") or std.mem.eql(u8, t2.data.sval.items, "["))) {
            const s2 = try token_text(state.allocator, t2, source, line_starts);
            defer state.allocator.free(s2);
            try state.out.appendSlice(s2);
            state.prev_token.* = t2;
            continue;
        }

        const s2 = try token_text(state.allocator, t2, source, line_starts);
        defer state.allocator.free(s2);
        try state.out.appendSlice(s2);

        // Track unary prefix ops so we don't insert a space after them.
        if (t2.type == .Operator) {
            const op2 = t2.data.sval.items;
            if ((std.mem.eql(u8, op2, "-") or std.mem.eql(u8, op2, "+") or std.mem.eql(u8, op2, "&") or std.mem.eql(u8, op2, "*"))) {
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
                        if (std.mem.eql(u8, kw, "ret") or std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "elif") or std.mem.eql(u8, kw, "for")) break :blk true;
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

        if (starts_import_stmt or starts_global_stmt) {
            // Collect up to ';'
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

    // Ensure exactly one trailing newline.
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append('\n');
    }

    // Overwrite input file in-place.
    try tp.ifile.writePositionalAll(io, out.items, 0);
    try tp.ifile.setLength(io, out.items.len);
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
pub fn compile_and_run(allocator: mem.Allocator, io: std.Io, c_file_or_content: []const u8, is_file: bool, input_file: []const u8, program_args: []const []const u8) !void {
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

    // Compile the C file
    {
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
                try append_default_compile_args(allocator, &argv_list, flavor, c_path, exe_file);
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
                std.Io.File.stderr().writeStreamingAll(io, "Compilation error:\n") catch {};
                std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
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
                try append_default_compile_args(allocator, &argv_list, candidate.flavor, c_path, exe_file);

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
                    std.Io.File.stderr().writeStreamingAll(io, "Compilation error:\n") catch {};
                    std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
                    return CliError.CompilationFailed;
                }

                break;
            }

            if (!any_compiler_found) return CliError.MissingCCompiler;
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
