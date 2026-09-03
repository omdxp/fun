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
        cli.CliError.ManifestNotFound => {
            stderr.writeStreamingAll(io, "Error: no fun.toml manifest found in the current directory\n") catch {};
        },
        cli.CliError.MissingFuzzTarget => {
            stderr.writeStreamingAll(io, "Error: fuzz target name is required after -fuzz-target\n") catch {};
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

    // `fun build`: reads `./fun.toml` and compiles each declared `[[exe]]`
    // target into `fun-out/bin/`. No compile pipeline / CliOptions needed
    // for this one -- it's a manifest-driven multi-file operation, not a
    // single `-in <file>` compile.
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "build")) {
        const debug_info = blk: {
            for (argv[1..]) |a| {
                if (std.mem.eql(u8, a, "-g")) break :blk true;
            }
            break :blk false;
        };
        cli.run_build(global_allocator, init.io, debug_info) catch |err| print_error_and_exit(init.io, err);
        return;
    }

    // `fun test` (no path) or `fun test <dir>` runs every `.fn` file under
    // that root (`.` by default) that declares a `test` block, one compile
    // pass each, and reports an aggregate summary -- rather than requiring
    // a hand-written loop over individual files. Only takes this path when
    // there's no path argument, or the argument names an existing
    // directory; `fun test <file.fn>` keeps the single-file form below.
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "test")) {
        // A path argument that starts with '-' is a flag, not a path (e.g.
        // `fun test -g`); everything else follows `fun test <file.fn>`'s
        // existing rule of treating argv[1] as the path when present.
        const has_path_arg = argv.len >= 2 and argv[1].len > 0 and argv[1][0] != '-';
        const named_path_is_file = has_path_arg and std.mem.endsWith(u8, argv[1], ".fn") and !cli.is_directory(init.io, argv[1]);
        if (!named_path_is_file) {
            const root: []const u8 = if (has_path_arg) argv[1] else ".";
            const debug_info = blk: {
                for (argv[1..]) |a| {
                    if (std.mem.eql(u8, a, "-g")) break :blk true;
                }
                break :blk false;
            };
            cli.run_test_suite(global_allocator, init.io, root, debug_info) catch |err| print_error_and_exit(init.io, err);
            return;
        }
    }

    // `fun fuzz` (no path) or `fun fuzz <dir>` is the directory-wide
    // counterpart to `fun test`'s above: every `fuzz` target across every
    // `.fn` file under that root, each run for a short bounded budget
    // (`FUN_FUZZ_DEFAULT_SECONDS`, default 30s) rather than the open-ended
    // campaign a single named target normally gets -- meant for a CI-style
    // "did anything regress" sweep, not a real fuzzing session. A target
    // name only makes sense alongside a specific file, so this form never
    // takes one; `fun fuzz <file.fn> [target]` keeps the single-target form
    // below.
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "fuzz")) {
        const has_path_arg = argv.len >= 2 and argv[1].len > 0 and argv[1][0] != '-';
        const named_path_is_file = has_path_arg and std.mem.endsWith(u8, argv[1], ".fn") and !cli.is_directory(init.io, argv[1]);
        if (!named_path_is_file) {
            const root: []const u8 = if (has_path_arg) argv[1] else ".";
            const debug_info = blk: {
                for (argv[1..]) |a| {
                    if (std.mem.eql(u8, a, "-g")) break :blk true;
                }
                break :blk false;
            };
            cli.run_fuzz_suite(global_allocator, init.io, root, debug_info) catch |err| print_error_and_exit(init.io, err);
            return;
        }
    }

    // `fun test <path> [...rest]` is shorthand for `fun -in <path> -test
    // [...rest]`, mirroring `zig test <path>`. Only rewritten when a path
    // actually follows "test" -- otherwise pass argv through unchanged so
    // `cli.parse_args` reports its own (still sensible) missing-input error.
    //
    // `fun fuzz <path> [<target>] [...rest]` is the same idea for fuzz mode
    // -- `<target>` is optional (a file with exactly one `fuzz` block
    // doesn't need to name it) and, when present, is just a bare word
    // (doesn't start with `-`), distinguishing it from a following flag
    // like `--`.
    const effective_argv: []const []const u8 = blk: {
        if (argv.len >= 2 and std.mem.eql(u8, argv[0], "test")) {
            var rewritten = global_allocator.alloc([]const u8, argv.len + 1) catch |err| print_error_and_exit(init.io, err);
            rewritten[0] = "-in";
            rewritten[1] = argv[1];
            rewritten[2] = "-test";
            for (argv[2..], 0..) |a, i| rewritten[3 + i] = a;
            break :blk rewritten;
        }
        if (argv.len >= 2 and std.mem.eql(u8, argv[0], "fuzz")) {
            const has_target = argv.len >= 3 and argv[2].len > 0 and argv[2][0] != '-';
            const extra: usize = if (has_target) 2 else 1;
            var rewritten = global_allocator.alloc([]const u8, argv.len + extra) catch |err| print_error_and_exit(init.io, err);
            rewritten[0] = "-in";
            rewritten[1] = argv[1];
            rewritten[2] = "-fuzz";
            if (has_target) {
                rewritten[3] = "-fuzz-target";
                rewritten[4] = argv[2];
                for (argv[3..], 0..) |a, i| rewritten[5 + i] = a;
            } else {
                for (argv[2..], 0..) |a, i| rewritten[3 + i] = a;
            }
            break :blk rewritten;
        }
        break :blk argv;
    };

    const options = cli.parse_args(global_allocator, init.io, effective_argv) catch |err| print_error_and_exit(init.io, err);
    defer cli.free_options(global_allocator, options);

    if (options.fmt_all) {
        cli.format_file_and_imports_in_place(global_allocator, init.io, options.input_file) catch |err| print_error_and_exit(init.io, err);
        return;
    }

    if (options.fmt_check) {
        const already_formatted = cli.format_file_check(global_allocator, init.io, options.input_file) catch |err| print_error_and_exit(init.io, err);
        if (!already_formatted) {
            const stderr = std.Io.File.stderr();
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}\n", .{options.input_file}) catch options.input_file;
            stderr.writeStreamingAll(init.io, msg) catch {};
            std.process.exit(1);
        }
        return;
    }

    if (options.fmt_check_all) {
        const offenders = cli.collect_unformatted_fun_files(global_allocator, init.io, options.input_file) catch |err| print_error_and_exit(init.io, err);
        defer cli.free_owned_paths(global_allocator, offenders);

        if (offenders.len != 0) {
            const stderr = std.Io.File.stderr();
            for (offenders) |path| {
                stderr.writeStreamingAll(init.io, path) catch {};
                stderr.writeStreamingAll(init.io, "\n") catch {};
            }
            std.process.exit(1);
        }
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

    // Run the compilation pipeline (lex -> parse -> AST -> transpile -> compile/run)
    // on a dedicated thread with a large stack. The recursive-descent parser, AST
    // printer, type checker, and codegen all walk the expression tree with native
    // recursion; on the default ~8-16 MB main-thread stack, deeply nested or very
    // long expressions overflow and segfault. A large stack lets legitimate deep
    // code compile, and the in-pass `max_expr_recursion_depth` guard reports a clean
    // `ExpressionTooDeep` error before even this stack is exhausted on truly
    // pathological input. `print_error_and_exit` calls `std.process.exit`, which
    // terminates the whole process from the worker thread, so error handling is
    // unaffected by running off the main thread.
    const PipelineCtx = struct { allocator: std.mem.Allocator, io: std.Io, options: @TypeOf(options) };
    const ctx = PipelineCtx{ .allocator = global_allocator, .io = init.io, .options = options };
    const thread = std.Thread.spawn(.{ .stack_size = pipeline_stack_size }, run_pipeline, .{ctx}) catch {
        // Spawn failed (e.g. resource limits) — fall back to running inline on the
        // main thread. Correctness is unchanged; only the deep-recursion headroom
        // is reduced (the in-pass depth guard still prevents a hard crash).
        run_pipeline(.{ .allocator = global_allocator, .io = init.io, .options = options });
        return;
    };
    thread.join();
}

/// Stack size for the compilation worker thread (256 MiB). Generous headroom for
/// the recursive-descent passes on deeply nested expressions, well above what the
/// `max_expr_recursion_depth` guard permits, so the guard fires first.
const pipeline_stack_size: usize = 256 * 1024 * 1024;

fn run_pipeline(ctx: anytype) void {
    const global_allocator = ctx.allocator;
    const options = ctx.options;
    const io = ctx.io;

    var tp = codegen.TranspileProcess.init(
        global_allocator,
        options.input_file,
        options.output_file,
        .{
            .exec = options.exec,
            .outf = options.outf,
            .ast = options.print_ast,
            // Skip C emission when we only need diagnostics (exec=false, no output file).
            // This avoids the full codegen pass and roughly halves compile time.
            .diag_only = !options.exec and !options.outf and !options.print_ast,
            .debug_info = options.debug_info,
            .emit_unused_warnings = options.warn_unused,
            .warn_unused_lenient = options.warn_unused_lenient,
            .test_mode = options.test_mode,
            .fuzz_mode = options.fuzz_mode,
        },
    ) catch |err| print_error_and_exit(io, err);
    tp.fuzz_target = options.fuzz_target;

    var lp = lexer.LexProcess.init(&tp);
    var pp = parser.ParseProcess.init(&tp);
    defer {
        lp.deinit();
        tp.deinit();
    }

    lp.lex() catch |err| print_error_and_exit(io, err);
    pp.parse() catch |err| print_error_and_exit(io, err);

    if (tp.flags.ast) {
        var ast_buf: [65536]u8 = undefined;
        var ast_writer = std.Io.File.stdout().writer(io, &ast_buf);
        for (tp.nodes.items()) |node| {
            utils.print_node(node, &ast_writer.interface, 0) catch |err| print_error_and_exit(io, err);
        }
        // The writer buffers into `ast_buf`; without an explicit flush the AST
        // output is silently dropped on exit (this is why `-ast` printed nothing).
        ast_writer.interface.flush() catch |err| print_error_and_exit(io, err);
    }

    tp.transpile() catch |err| print_error_and_exit(io, err);

    if (tp.flags.exec) {
        if (tp.flags.outf) {
            cli.compile_and_run(global_allocator, io, options.output_file, true, options.input_file, options.program_args, options.debug_info, options.fuzz_mode) catch |err| print_error_and_exit(io, err);
        } else if (tp.get_output()) |output| {
            cli.compile_and_run(global_allocator, io, output, false, options.input_file, options.program_args, options.debug_info, options.fuzz_mode) catch |err| print_error_and_exit(io, err);
        }
    }
}
