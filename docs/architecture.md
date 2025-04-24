# fun Architecture

## Overview
- Written in Zig
- Transpiles fun code to C
- CLI tool for compilation and execution

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
