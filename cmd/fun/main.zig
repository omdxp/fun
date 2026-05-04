const std = @import("std");
const heap = std.heap;
const build_options = @import("build_options");
const token = @import("lexer").token;
const codegen = @import("codegen");
const lexer = @import("lexer");
const parser = @import("parser");
const utils = @import("utils");
const cli = @import("cli");

fn print_error_and_exit(io: std.Io, err: anyerror) noreturn {
    const stderr = std.Io.File.stderr();
    switch (err) {
        cli.CliError.MissingInputFile => {
            stderr.writeStreamingAll(io, "Error: Input file is required\n") catch {};
        },
        cli.CliError.MissingOutputFile => {
            stderr.writeStreamingAll(io, "Error: Output file name is required when using -out flag\n") catch {};
        },
        cli.CliError.InvalidInputExtension => {
            stderr.writeStreamingAll(io, "Error: Input file must have .fn extension\n") catch {};
        },
        cli.CliError.InvalidOutputExtension => {
            stderr.writeStreamingAll(io, "Error: Output file must have .c extension\n") catch {};
        },
        cli.CliError.CompilationFailed => {
            stderr.writeStreamingAll(io, "Error: C compilation failed.\n") catch {};
        },
        cli.CliError.MissingCCompiler => {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "Error: C compiler not found. Tried defaults for this platform: {s}. Set FUN_CC/FUN_CC_ARGS to override.\n",
                .{cli.default_compiler_hint()},
            ) catch "Error: C compiler not found.\n";
            stderr.writeStreamingAll(io, msg) catch {};
        },
        cli.CliError.ExecutionFailed => {
            stderr.writeStreamingAll(io, "Error: Execution of compiled code failed.\n") catch {};
        },
        cli.CliError.ShowHelp => {
            std.process.exit(0);
        },
        // Formatting uses the same lexer/transpiler error types; they are printed elsewhere.
        error.FileNotFound => {
            stderr.writeStreamingAll(io, "Error: Input file not found\n") catch {};
        },
        else => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: {s}\n", .{@errorName(err)}) catch "Error: unknown\n";
            stderr.writeStreamingAll(io, msg) catch {};
        },
    }

    std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    var arena = heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const global_allocator = arena.allocator();

    const all_args = init.minimal.args.toSlice(global_allocator) catch |err| print_error_and_exit(init.io, err);
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

    const options = cli.parse_args(global_allocator, init.io, argv) catch |err| print_error_and_exit(init.io, err);

    if (options.fmt_all) {
        cli.format_file_and_imports_in_place(global_allocator, init.io, options.input_file) catch |err| print_error_and_exit(init.io, err);
        return;
    }

    if (options.fmt_diag) {
        // Format in-place, then fall through to full compilation so diagnostics
        // are emitted to stderr. Used by the language server (fls) to combine
        // formatting + diagnostics in a single subprocess call.
        cli.format_file_in_place(global_allocator, init.io, options.input_file) catch {};
    }

    if (options.fmt and !options.fmt_diag) {
        cli.format_file_in_place(global_allocator, init.io, options.input_file) catch |err| print_error_and_exit(init.io, err);
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
    ) catch |err| print_error_and_exit(init.io, err);

    var lp = lexer.LexProcess.init(&tp);
    var pp = parser.ParseProcess.init(&tp);
    defer {
        lp.deinit();
        tp.deinit();
    }

    lp.lex() catch |err| print_error_and_exit(init.io, err);
    pp.parse() catch |err| print_error_and_exit(init.io, err);

    if (tp.flags.ast) {
        var ast_buf: [65536]u8 = undefined;
        var ast_writer = std.Io.File.stdout().writer(init.io, &ast_buf);
        for (tp.nodes.items()) |node| {
            utils.print_node(node, &ast_writer.interface, 0) catch |err| print_error_and_exit(init.io, err);
        }
    }

    tp.transpile() catch |err| print_error_and_exit(init.io, err);

    if (tp.flags.exec) {
        if (tp.flags.outf) {
            cli.compile_and_run(global_allocator, init.io, options.output_file, true, options.input_file, options.program_args) catch |err| print_error_and_exit(init.io, err);
        } else if (tp.get_output()) |output| {
            cli.compile_and_run(global_allocator, init.io, output, false, options.input_file, options.program_args) catch |err| print_error_and_exit(init.io, err);
        }
    }
}
