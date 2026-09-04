# Fun Architecture

## Overview

Fun transpiles Fun source code to C. This architecture keeps the compiler implementation compact while allowing generated programs to build against widely available platform toolchains. The compiler and language server are themselves written in Fun and compile themselves.

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

- `src/ast/`: the shared AST node types every other stage reads and produces
- `src/lexer/`: tokenizes source input
- `src/parser/`: builds the AST, resolves imports, and formats source
- `src/semantics/`: type checking and warning analysis
- `src/codegen/`: lowers a checked program to C
- `src/cli/`: the `fun` command-line driver
- `src/fls/`: the language server
- `src/tests/`: parser, typecheck, code generation, CLI, warning, and end-to-end coverage
- `stdlib/`: standard library source
- `examples/`: runnable language and standard-library examples

## Build System

`fun build` reads [fun.toml](../fun.toml) and compiles the `[[exe]]` targets it declares (`fun`, `fls`) into `fun-out/bin/`. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full validation workflow.
