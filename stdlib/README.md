
# Fun Standard Library

This directory contains standard library modules for the Fun language.

## Structure

- **std/**: Core standard library modules (function signatures only)

Fun maps `imp std.*;` imports to C standard headers during code generation. Actual implementations are provided by the C compiler/linker.

Signature-only modules support tooling (IDE completion, future LSP).

Installed location (via `zig build install`):
- `share/fun/std/*.fn`
