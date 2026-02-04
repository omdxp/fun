
# Fun Standard Library

This directory contains standard library modules for the Fun language.

## Structure

- **std/**: Standard library namespace
	- **std/c/**: C standard-library signature modules
	- **std/** (pure Fun): core utilities (string, vec, map, set, math, io, fs, path, time, rand, net, cli, log, json, toml)

## Modules

### Pure Fun modules (std/*)

Note: Fun is 64-bit by default (`num` → `int64_t`, `dec` → `double`).

- **std/array.fn**: Fixed-size array helpers.
- **std/cli.fn**: Command-line argument parsing helpers.
- **std/fs.fn**: File system helpers built on C stdio.
- **std/io.fn**: Simple buffered I/O helpers.
- **std/json.fn**: Minimal JSON stringify utilities.
- **std/log.fn**: Simple logging with levels.
- **std/map.fn**: String-keyed hash map.
- **std/math.fn**: Math helpers.
- **std/net.fn**: Basic URL parsing and HTTP GET builder.
- **std/path.fn**: Path helpers (join/basename/dirname/extname).
- **std/rand.fn**: Simple PRNG utilities.
- **std/string.fn**: String helpers (len, trim, split, join, contains, etc.).
- **std/time.fn**: Time helpers (epoch, formatting).
- **std/toml.fn**: Minimal TOML parse/stringify for flat key/value.
- **std/vec.fn**: Dynamic vector helpers.

### C signature modules (std/c/*)

- **std/c/def.fn**: Common C definitions and constants.
- **std/c/io.fn**: stdio bindings (FILE, printf, fopen, etc.).
- **std/c/mem.fn**: stdlib bindings (malloc/free, env, system, etc.).
- **std/c/string.fn**: string.h bindings (strlen, memcpy, memset, etc.).
- **std/c/time.fn**: time.h bindings (time, localtime, strftime, etc.).

Fun maps `imp std.c.*;` imports to C standard headers during code generation. Actual implementations are provided by the C compiler/linker.

Signature-only modules support tooling (IDE completion, future LSP).

Installed location (via `zig build install`):
- `share/fun/stdlib/std/c/*.fn`
