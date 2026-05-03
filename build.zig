const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const fun_version_opt = b.option([]const u8, "version", "version string for `fun --version` (set by release workflow)");
    const fun_version = blk: {
        const v = fun_version_opt orelse "0.0.0";
        // Guard against common CI/local mistakes like passing a shell variable literally
        // (e.g. `-Dversion=$tag` in cmd.exe).
        if (v.len == 0) break :blk "0.0.0";
        if (std.mem.eql(u8, v, "$tag")) break :blk "0.0.0";
        break :blk v;
    };

    // --- Define Core Library Modules ---

    const utils_module = b.createModule(.{
        .root_source_file = b.path("modules/utils/utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ast_module = b.createModule(.{
        .root_source_file = b.path("modules/ast/ast.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lexer_module = b.createModule(.{
        .root_source_file = b.path("modules/lexer/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const parser_module = b.createModule(.{
        .root_source_file = b.path("modules/parser/parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const semantics_module = b.createModule(.{
        .root_source_file = b.path("modules/semantics/semantics.zig"),
        .target = target,
        .optimize = optimize,
    });

    const codegen_module = b.createModule(.{
        .root_source_file = b.path("modules/codegen/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("modules/cli/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    ast_module.addImport("utils", utils_module);
    ast_module.addImport("lexer", lexer_module);
    ast_module.addImport("semantics", semantics_module);

    lexer_module.addImport("utils", utils_module);
    lexer_module.addImport("codegen", codegen_module);

    parser_module.addImport("utils", utils_module);
    parser_module.addImport("ast", ast_module);
    parser_module.addImport("lexer", lexer_module);
    parser_module.addImport("codegen", codegen_module);
    parser_module.addImport("semantics", semantics_module);

    semantics_module.addImport("utils", utils_module);
    semantics_module.addImport("ast", ast_module);

    codegen_module.addImport("utils", utils_module);
    codegen_module.addImport("ast", ast_module);
    codegen_module.addImport("semantics", semantics_module);
    codegen_module.addImport("lexer", lexer_module);
    codegen_module.addImport("parser", parser_module);

    cli_module.addImport("utils", utils_module);
    cli_module.addImport("lexer", lexer_module);
    cli_module.addImport("parser", parser_module);
    cli_module.addImport("semantics", semantics_module);
    cli_module.addImport("codegen", codegen_module);

    utils_module.addImport("lexer", lexer_module);
    utils_module.addImport("ast", ast_module);
    utils_module.addImport("semantics", semantics_module);

    // --- Define Main Executable ---
    const exe_module = b.createModule(.{
        .root_source_file = b.path("cmd/fun/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- Link Modules to Executable ---
    exe_module.addImport("cli", cli_module);
    exe_module.addImport("utils", utils_module);
    exe_module.addImport("codegen", codegen_module);
    exe_module.addImport("lexer", lexer_module);
    exe_module.addImport("parser", parser_module);

    // --- Build Executable ---
    const exe = b.addExecutable(.{
        .name = "fun",
        .root_module = exe_module,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", fun_version);
    exe.root_module.addOptions("build_options", build_options);

    // --- Define Language Server Executable (fls) ---
    const fls_module = b.createModule(.{
        .root_source_file = b.path("cmd/fls/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    fls_module.addImport("utils", utils_module);
    fls_module.addImport("ast", ast_module);
    fls_module.addImport("lexer", lexer_module);
    fls_module.addImport("parser", parser_module);
    fls_module.addImport("semantics", semantics_module);
    fls_module.addImport("codegen", codegen_module);

    const fls_exe = b.addExecutable(.{
        .name = "fls",
        .root_module = fls_module,
    });

    // Keep fls and fun on the same version string.
    fls_exe.root_module.addOptions("build_options", build_options);

    const no_bin = b.option(bool, "no-bin", "skip emitting binary") orelse false;
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
        b.getInstallStep().dependOn(&fls_exe.step);
    } else {
        b.installArtifact(exe);
        // Always install fls.exe as the language server, even on Windows.
        b.installArtifact(fls_exe);
    }

    // --- Install Fun standard library signature files ---
    // These are tooling-oriented Fun modules (signatures only) shipped alongside the compiler.
    const install_stdlib = b.addInstallDirectory(.{
        .source_dir = b.path("stdlib"),
        .install_dir = .prefix,
        .install_subdir = "share/fun",
    });
    b.getInstallStep().dependOn(&install_stdlib.step);

    const run_cmd = b.addRunArtifact(exe);
    // Make `zig build run -- -in .\relative\path.fn` resolve relative paths
    // from the project root (instead of Zig's cache directory).
    run_cmd.cwd = b.path(".");
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- Define Unit Tests ---
    // Create single consolidated test module
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/main_test.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });

    // Add all modules as imports to the test module
    test_module.addImport("utils", utils_module);
    test_module.addImport("ast", ast_module);
    test_module.addImport("lexer", lexer_module);
    test_module.addImport("parser", parser_module);
    test_module.addImport("semantics", semantics_module);
    test_module.addImport("codegen", codegen_module);
    test_module.addImport("cli", cli_module);

    const main_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    // Some tests (e.g. LSP e2e) expect paths like zig-out/bin/* relative to the repo root.
    run_main_tests.cwd = b.path(".");

    // Stage test binaries into a separate directory so Windows file locks on
    // `zig-out/bin/fls.exe` don't break `zig build test`.
    const test_exe_dir = "zig-out/test-bin";
    const exe_suffix: []const u8 = if (builtin.os.tag == .windows) ".exe" else "";
    const install_test_fun = b.addInstallFile(exe.getEmittedBin(), b.fmt("{s}/fun{s}", .{ test_exe_dir, exe_suffix }));
    const install_test_fls = b.addInstallFile(fls_exe.getEmittedBin(), b.fmt("{s}/fls{s}", .{ test_exe_dir, exe_suffix }));
    const stage_test_bins = b.step("stage-test-bins", "Stage fun/fls into zig-out/test-bin for e2e tests");
    stage_test_bins.dependOn(&install_test_fun.step);
    stage_test_bins.dependOn(&install_test_fls.step);
    run_main_tests.*.step.dependOn(stage_test_bins);
    run_main_tests.setEnvironmentVariable("FLS_E2E_EXE_DIR", test_exe_dir);
    // Ensure stdlib resolution uses the repo stdlib during tests.
    run_main_tests.setEnvironmentVariable("FUN_STDLIB_DIR", "stdlib");

    // --- Define fls (language server) Unit Tests ---
    // We keep fls tests close to the implementation (cmd/fls/main.zig) and wire them into `zig build test`.
    const fls_test_module = b.createModule(.{
        .root_source_file = b.path("cmd/fls/main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    fls_test_module.addImport("utils", utils_module);
    fls_test_module.addImport("ast", ast_module);
    fls_test_module.addImport("lexer", lexer_module);
    fls_test_module.addImport("parser", parser_module);
    fls_test_module.addImport("semantics", semantics_module);
    fls_test_module.addImport("codegen", codegen_module);

    const fls_tests = b.addTest(.{ .root_module = fls_test_module });
    const run_fls_tests = b.addRunArtifact(fls_tests);
    run_fls_tests.cwd = b.path(".");
    // Ensure fls unit tests use the repo stdlib and avoid any global installs.
    // This keeps stdlib resolution stable even when tests index temp documents.
    run_fls_tests.setEnvironmentVariable("FUN_STDLIB_DIR", "stdlib");

    const test_step = b.step("test", "Run unit tests");
    // Ensure compiler + language server binaries exist for tests that spawn them.
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_fls_tests.step);
}
