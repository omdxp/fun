# fun Standard Library (Signatures)

This directory contains the Fun standard library modules written in Fun.

Important: these files intentionally contain **function signatures only** (no implementations).
The Fun compiler maps `imp std.*;` imports to C standard headers during code generation, and the
C compiler/linker provides the actual implementations.

These signature-only modules exist primarily to support tooling (e.g. IDE completion, future LSP).

Installed location (via `zig build install`):
- `share/fun/std/*.fn`
