# Fun Modules

This directory contains the core implementation modules for the Fun compiler, tooling, and language server.

## Module Overview

- **ast**: abstract syntax tree structures and traversal support
- **cli**: command-line parsing, command dispatch, and user-facing workflow logic
- **codegen**: C generation and transpilation logic
- **fls**: language-server implementation and editor-facing tooling support
- **lexer**: lexical analysis and token production
- **parser**: syntax parsing and AST construction
- **semantics**: symbol resolution, type checking, and semantic validation
- **utils**: shared helpers used across compiler and tooling layers

Where a submodule includes its own README or additional documentation, that file should be treated as the module-local source of truth for implementation details.
