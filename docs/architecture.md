# fun Architecture

## Overview
- Written in Zig
- Transpiles fun code to C
- CLI tool for compilation and execution
- Numeric model includes `num`/`dec`, fixed-width scalars (`i8`..`i64`, `u8`..`u64`, `f32`, `f64`), and arbitrary-width integers (`iN`, `uN`)

## Main Components
- **Lexer**: Tokenizes source code
- **Parser**: Builds AST from tokens
- **Transpiler**: Converts AST to C code
- **CLI**: Handles user input and options

## Directory Structure
- `modules/` — Compiler modules
- `cmd/` — CLI entrypoint
- `examples/` — Example programs
- `tests/` — Test suite

## Build
- Uses Zig build system

---
For more, see [modules/README.md](../modules/README.md).
