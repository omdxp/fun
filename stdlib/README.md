
# Fun Standard Library

This directory contains standard library modules for the Fun language.

## Structure

- **std/**: Standard library namespace
	- **std/c/**: C standard-library signature modules
	- **std/** (pure Fun): core utilities (string, vec, map, set, math, io, fs, path, time, rand, net, cli, log, json, toml)

## Modules

### Pure Fun modules (std/*)

Note: `num`/`dec` are 64-bit by default (`int64_t`/`double`), and Fun also supports fixed-width numeric types (`i8`..`i64`, `u8`..`u64`, `f32`, `f64`) plus arbitrary-width integers (`iN`, `uN`).

- **std/array.fn**: Fixed-size array helpers (get/set/swap/reverse).
- **std/cli.fn**: Command-line argument parsing helpers (long/short flags, bundling, `--` stop).
- **std/collections.fn**: Collection quirks (len/is_empty) aligned with std.quirks.
- **std/fs.fn**: File system helpers (exists, read/write, copy, read_lines).
- **std/io.fn**: File helpers (append, size, read bytes, read line, flush).
- **std/json.fn**: JSON stringify/parse for string objects and arrays (with escaping, keys/has/remove).
- **std/log.fn**: Logging with levels and typed log helpers.
- **std/map.fn**: String-keyed hash map with keys and defaults.
- **std/math.fn**: Math helpers.
- **std/net.fn**: Basic URL parsing, HTTP GET builder, and POSIX TCP/HTTP helpers.
- **std/option.fn**: Generic `Option<T>` container with `some<T>`/`none<T>` helpers.
- **std/c/net.fn**: POSIX socket bindings (sys/socket.h, netinet/in.h, arpa/inet.h, unistd.h).
- **std/sys.fn**: Environment, process control, and randomness helpers.
- **std/path.fn**: Path helpers (join, join_many, basename, dirname, extname, strip_ext, change_ext, is_abs).
- **std/rand.fn**: PRNG utilities (range_dec, chance, shuffle).
- **std/string.fn**: String helpers (count, strip prefix/suffix, split lines, replace, case conversion, repeat, etc.).
- **std/time.fn**: Time helpers (epoch, formatting, UTC, diffs).
- **std/toml.fn**: Minimal TOML parse/stringify for flat key/value.
- **std/vec.fn**: Dynamic vector helpers (reserve/insert/remove/pop/swap_remove/extend/resize/shrink_to_fit).
- **std/error.fn**: Error value helpers (construct/check ok/err).
- **std/result.fn**: Generic `Result<T>` container with `ok<T>`/`err<T>` helpers.

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
