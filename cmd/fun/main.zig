const std = @import("std");
const heap = std.heap;
const build_options = @import("build_options");
const token = @import("lexer").token;
const codegen = @import("codegen");
const lexer = @import("lexer");
const parser = @import("parser");
const utils = @import("utils");
const cli = @import("cli");

fn print_error_and_exit(err: anyerror) noreturn {
    switch (err) {
        cli.CliError.MissingInputFile => {
            std.debug.print("Error: Input file is required\n", .{});
        },
        cli.CliError.MissingOutputFile => {
            std.debug.print("Error: Output file name is required when using -out flag\n", .{});
        },
        cli.CliError.InvalidInputExtension => {
            std.debug.print("Error: Input file must have .fn extension\n", .{});
        },
        cli.CliError.InvalidOutputExtension => {
            std.debug.print("Error: Output file must have .c extension\n", .{});
        },
        cli.CliError.CompilationFailed => {
            std.debug.print("Error: C compilation failed.\n", .{});
        },
        cli.CliError.MissingCCompiler => {
            std.debug.print(
                "Error: C compiler not found. Tried defaults for this platform: {s}. Set FUN_CC/FUN_CC_ARGS to override.\n",
                .{cli.default_compiler_hint()},
            );
        },
        cli.CliError.ExecutionFailed => {
            std.debug.print("Error: Execution of compiled code failed.\n", .{});
        },
        cli.CliError.ShowHelp => {
            std.process.exit(0);
        },
        // Formatting uses the same lexer/transpiler error types; they are printed elsewhere.
        error.FileNotFound => {
            std.debug.print("Error: Input file not found\n", .{});
        },
        else => {
            std.debug.print("Error: {s}\n", .{@errorName(err)});
        },
    }

    std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    var arena = heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const global_allocator = arena.allocator();

    const all_args = init.minimal.args.toSlice(global_allocator) catch |err| print_error_and_exit(err);
    // Skip the executable name.
    const argv = if (all_args.len > 0) all_args[1..] else all_args[0..0];

    // Handle `-version` without requiring other flags.
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "-version") or std.mem.eql(u8, arg, "--version")) {
            var ver_buf: [256]u8 = undefined;
            const ver_str = std.fmt.bufPrint(&ver_buf, "{s}\n", .{build_options.version}) catch build_options.version;
            std.Io.File.stdout().writeStreamingAll(init.io, ver_str) catch {};
            return;
        }
    }

    const options = cli.parse_args(global_allocator, argv) catch |err| print_error_and_exit(err);

    if (options.fmt_all) {
        cli.format_file_and_imports_in_place(global_allocator, init.io, options.input_file) catch |err| print_error_and_exit(err);
        return;
    }

    if (options.fmt) {
        cli.format_file_in_place(global_allocator, init.io, options.input_file) catch |err| print_error_and_exit(err);
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

    if (tp.flags.ast) {
        var ast_buf: [65536]u8 = undefined;
        var ast_writer = std.Io.File.stdout().writer(init.io, &ast_buf);
        for (tp.nodes.items()) |node| {
            utils.print_node(node, &ast_writer.interface, 0) catch |err| print_error_and_exit(err);
        }
    }

    tp.transpile() catch |err| print_error_and_exit(err);

    if (tp.flags.exec) {
        if (tp.flags.outf) {
            cli.compile_and_run(global_allocator, init.io, options.output_file, true, options.input_file, options.program_args) catch |err| print_error_and_exit(err);
        } else if (tp.get_output()) |output| {
            cli.compile_and_run(global_allocator, init.io, output, false, options.input_file, options.program_args) catch |err| print_error_and_exit(err);
        }
    }
}
