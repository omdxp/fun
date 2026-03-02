const std = @import("std");
const heap = std.heap;
const builtin = @import("builtin");
const build_options = @import("build_options");
const token = @import("lexer").token;
const codegen = @import("codegen");
const lexer = @import("lexer");
const parser = @import("parser");
const utils = @import("utils");
const cli = @import("cli");

var debug_allocator: heap.DebugAllocator(.{}) = .init;

fn print_error_and_exit(err: anyerror) noreturn {
    const stderr = std.io.getStdErr().writer();

    switch (err) {
        cli.CliError.MissingInputFile => {
            _ = stderr.writeAll("Error: Input file is required\n") catch {};
        },
        cli.CliError.MissingOutputFile => {
            _ = stderr.writeAll("Error: Output file name is required when using -out flag\n") catch {};
        },
        cli.CliError.InvalidInputExtension => {
            _ = stderr.writeAll("Error: Input file must have .fn extension\n") catch {};
        },
        cli.CliError.InvalidOutputExtension => {
            _ = stderr.writeAll("Error: Output file must have .c extension\n") catch {};
        },
        cli.CliError.CompilationFailed => {
            _ = stderr.writeAll("Error: C compilation failed.\n") catch {};
        },
        cli.CliError.MissingCCompiler => {
            stderr.print(
                "Error: C compiler not found. Tried defaults for this platform: {s}. Set FUN_CC/FUN_CC_ARGS to override.\n",
                .{cli.default_compiler_hint()},
            ) catch {};
        },
        cli.CliError.ExecutionFailed => {
            _ = stderr.writeAll("Error: Execution of compiled code failed.\n") catch {};
        },
        cli.CliError.ShowHelp => {
            std.process.exit(0);
        },
        // Formatting uses the same lexer/transpiler error types; they are printed elsewhere.
        error.FileNotFound => {
            _ = stderr.writeAll("Error: Input file not found\n") catch {};
        },
        else => {
            stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
        },
    }

    std.process.exit(1);
}

pub fn main() void {
    const gpa, const is_debug = blk: {
        if (builtin.target.os.tag == .wasi) break :blk .{ heap.wasm_allocator, false };
        break :blk switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    var arena = heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const global_allocator = arena.allocator();

    // Handle `-version` without requiring other flags.
    {
        var args = std.process.argsWithAllocator(global_allocator) catch |err| print_error_and_exit(err);
        defer args.deinit();
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-version") or std.mem.eql(u8, arg, "--version")) {
                const stdout = std.io.getStdOut().writer();
                stdout.print("{s}\n", .{build_options.version}) catch |err| print_error_and_exit(err);
                return;
            }
        }
    }

    const options = cli.parse_args(global_allocator) catch |err| print_error_and_exit(err);

    if (options.fmt_all) {
        cli.format_file_and_imports_in_place(global_allocator, options.input_file) catch |err| print_error_and_exit(err);
        return;
    }

    if (options.fmt) {
        cli.format_file_in_place(global_allocator, options.input_file) catch |err| print_error_and_exit(err);
        return;
    }

    var tp = codegen.TranspileProcess.init(
        global_allocator,
        options.input_file,
        options.output_file,
        .{
            .exec = options.exec,
            .outf = options.outf,
            .ast = options.print_ast,
        },
    ) catch |err| print_error_and_exit(err);

    var lp = lexer.LexProcess.init(&tp);
    var pp = parser.ParseProcess.init(&tp);
    defer {
        lp.deinit();
        tp.deinit();
    }

    lp.lex() catch |err| print_error_and_exit(err);
    pp.parse() catch |err| print_error_and_exit(err);

    const stdout = std.io.getStdOut().writer();
    if (tp.flags.ast) {
        for (tp.nodes.items()) |node| {
            utils.print_node(node, stdout, 0) catch |err| print_error_and_exit(err);
        }
    }

    tp.transpile() catch |err| print_error_and_exit(err);

    if (tp.flags.exec) {
        if (tp.flags.outf) {
            cli.compile_and_run(global_allocator, options.output_file, true, options.input_file, options.program_args) catch |err| print_error_and_exit(err);
        } else if (tp.get_output()) |output| {
            cli.compile_and_run(global_allocator, output, false, options.input_file, options.program_args) catch |err| print_error_and_exit(err);
        }
    }
}
