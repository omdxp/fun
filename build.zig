const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

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
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("modules/cli/cli.zig"),
        .target = target,
        .optimize = optimize,
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

    const no_bin = b.option(bool, "no-bin", "skip emitting binary") orelse false;
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- Define Unit Tests ---
    // Create a test module that imports all other modules to run tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("cmd/fun/main.zig"), // Assuming tests can be run from/imported by main
        .target = target,
        .optimize = .Debug, // Use Debug optimize for tests
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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_tests.step);
}
