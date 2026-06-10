# Fun Architecture

## Overview

Fun is implemented in Zig and transpiles Fun source code to C. This architecture keeps the compiler implementation compact while allowing generated programs to build against widely available platform toolchains.

The project is organized around a clear front-end and code generation pipeline:

- lexical analysis and parsing
- semantic analysis and type checking
- transpilation to C
- CLI orchestration and tooling integration

The language model includes default 64-bit numeric types (`num`, `dec`), fixed-width scalars (`i8` through `i64`, `u8` through `u64`, `f32`, `f64`), and arbitrary-width integers (`iN`, `uN`).

## Compiler Pipeline

- **Lexer**: tokenizes source input into the stream consumed by later stages
- **Parser**: builds the AST and preserves enough structure for diagnostics and formatting
- **Semantics**: resolves symbols, validates types, and enforces language rules
- **Code generation / transpilation**: lowers validated Fun programs to C
- **CLI and tooling layers**: coordinate formatting, diagnostics, compilation, and editor-facing workflows

## Repository Layout

- `modules/`: compiler and tooling implementation modules
- `cmd/`: executable entrypoints such as the CLI and language server binaries
- `examples/`: runnable language and standard-library examples
- `tests/`: parser, typecheck, code generation, CLI, warning, and end-to-end coverage

## Build System

The repository uses the Zig build system to compile the compiler, language server, examples, and tests. Standard validation is driven through `zig build` and `zig build test --summary all`.

For module-level descriptions, see [modules/README.md](../modules/README.md).
