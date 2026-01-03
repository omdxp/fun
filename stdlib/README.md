
# Fun Standard Library

This directory contains standard library modules for the Fun language.

## Structure

- **std/**: Standard library namespace
	- **std/c/**: C standard-library signature modules

Fun maps `imp std.c.*;` imports to C standard headers during code generation. Actual implementations are provided by the C compiler/linker.

Signature-only modules support tooling (IDE completion, future LSP).

Installed location (via `zig build install`):
- `share/fun/stdlib/std/c/*.fn`
