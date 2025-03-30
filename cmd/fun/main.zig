const std = @import("std");
const heap = std.heap;
const token = @import("lexer").token;
const codegen = @import("codegen");
const lexer = @import("lexer");
const parser = @import("parser");
const utils = @import("utils");
const cli = @import("cli");

fn print_error_and_exit(err: anyerror) noreturn {
    const stderr = std.io.getStdErr().writer();

    if (err == cli.CliError.MissingInputFile) {
        stderr.writeAll("Error: Input file is required\n") catch {};
        std.process.exit(1);
    } else if (err == cli.CliError.MissingOutputFile) {
        stderr.writeAll("Error: Output file name is required when using -out flag\n") catch {};
        std.process.exit(1);
    } else if (err == cli.CliError.InvalidInputExtension) {
        stderr.writeAll("Error: Input file must have .fn extension\n") catch {};
        std.process.exit(1);
    } else if (err == cli.CliError.InvalidOutputExtension) {
        stderr.writeAll("Error: Output file must have .c extension\n") catch {};
        std.process.exit(1);
    } else if (err == cli.CliError.CompilationFailed) {
        std.process.exit(1);
    } else if (err == cli.CliError.ExecutionFailed) {
        std.process.exit(1);
    } else if (err == cli.CliError.ShowHelp) {
        std.process.exit(0);
    } else if (err == error.FileNotFound) {
        stderr.writeAll("Error: Input file not found\n") catch {};
        std.process.exit(1);
    } else {
        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    }
}

pub fn main() void {
    var gpa = heap.DebugAllocator(.{ .thread_safe = true, .safety = true }){};
    defer _ = gpa.deinit();
    var arena = heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const global_allocator = arena.allocator();

    const options = cli.parse_args(global_allocator) catch |err| print_error_and_exit(err);

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
        stdout.print("\n=== AST Nodes ===\n", .{}) catch |err| print_error_and_exit(err);
        for (tp.nodes.items(), 0..) |node, i| {
            stdout.print("\nNode {d}:\n", .{i}) catch |err| print_error_and_exit(err);
            utils.print_node(node, stdout, 0) catch |err| print_error_and_exit(err);
        }
    }

    tp.transpile() catch |err| print_error_and_exit(err);

    if (tp.flags.exec) {
        if (tp.flags.outf) {
            cli.compile_and_run(global_allocator, options.output_file, true, options.input_file) catch |err| print_error_and_exit(err);
        } else if (tp.get_output()) |output| {
            cli.compile_and_run(global_allocator, output, false, options.input_file) catch |err| print_error_and_exit(err);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
