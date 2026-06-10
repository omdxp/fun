# Fun Test Suite

This directory contains repository test coverage for the compiler, diagnostics, standard library, tooling behavior, and language-server end-to-end workflows.

## Test Organization

- `ast_test.zig`: AST construction and structure checks
- `cli_test.zig`: command-line behavior and option handling
- `codegen_test.zig`: transpilation and generated-code behavior
- `lexer_test.zig`: lexical analysis
- `main_test.zig`: integration-oriented compiler coverage
- `parser_test.zig`: parsing behavior and malformed-input handling
- `semantics_test.zig`: semantic analysis and type-check coverage
- `utils_test.zig`: utility-layer behavior
- `warnings_test.zig`: warning diagnostics and warning-control behavior

Additional files in this directory cover standard-library behavior, imports, formatting, FLS end-to-end coverage, and subsystem-specific regressions.

## Running Tests

Run the standard repository test suite with:

```bash
zig build test --summary all
```

For narrower local iteration, use the repository tasks or targeted commands documented in the workspace and build configuration.
