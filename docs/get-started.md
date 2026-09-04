# Get Started

## Overview

Fun is a statically-typed, C-transpiling language focused on performance
and clarity. The compiler emits readable C and relies on the system C
toolchain for linking and execution. It is self-hosted: the compiler and
its language server are themselves written in Fun and compile themselves.

The language provides high-level default numerics (`num`, `dec`),
fixed-width scalar types (`i32`, `u64`, `f32`, `f64`), and arbitrary-width
integers (`iN`, `uN`) so the same codebase can target ergonomic
application code and lower-level systems work, with practical concurrency
(virtual threads, channels, async/await) as a first-class part of the
language and standard library.

## Installation

Release assets are published as install bundles containing the compiler,
the standard library under `share/fun/`, and platform-specific install
assets.

- Windows releases are available as `.msi` installers and portable `.zip`
  archives, which preserve the same `bin/` and `share/fun/` layout as an
  installed release and include `README-portable.txt` with startup notes.
- Linux and macOS releases are tarballs with an `install.sh`/`uninstall.sh`
  pair. See Platforms & Compilers for the exact target matrix.

At runtime, the compiler discovers the standard library in this order:

1. `FUN_STDLIB_DIR`
2. `<exe>/../share/fun`
3. Common system install locations for the active platform

`std.c.*` modules are signature-only C interop definitions used for
typechecking and tooling; `std.*` modules without the `.c` namespace are
Fun-native standard library modules.

### Building from source

With a `fun` binary already on `PATH` (from a release, or a previous
build), rebuild the compiler and language server from this repository's
own source:

```sh
git clone https://github.com/omdxp/fun.git
cd fun
fun build
```

This reads `fun.toml` and produces `fun`/`fls` under `fun-out/bin/`.
Building with nothing installed at all needs a one-time bootstrap step
first; see `CONTRIBUTING.md` in the repository.

## Quickstart

Create `hello.fn`:

```fun
imp std.c.io;

fun main(str[] args) {
  printf("Hello, World!\n");
}
```

Run it:

```sh
fun -in hello.fn
```

`fun -in file.fn` compiles and runs a Fun program in one step, with
nothing else needed for a single-file script.

## Starting a project with `fun init`

For anything beyond a single script, `fun init [lib|exe|mix]` scaffolds a
real project: a `fun.toml` manifest, a `src/` directory with a starter
file, and a `.gitignore`, all in the current directory.

```sh
mkdir myproject && cd myproject
fun init
```

`kind` picks what gets scaffolded (`exe` is the default if omitted):

| Kind | Creates |
|---|---|
| `exe` | `src/main.fn`, plus a `[[exe]]` target in `fun.toml` |
| `lib` | `src/lib.fn`, plus a `[lib]` entry in `fun.toml` |
| `mix` | Both of the above |

`fun init` refuses to run if a `fun.toml` already exists in the current
directory, so it never overwrites an existing project.

## The build manifest (`fun.toml`)

A manifest declares build targets, not an import graph: `imp` already
does path-based module resolution, so `fun.toml` only needs to name which
entry file produces which binary.

```toml
[package]
name = "myproject"
version = "0.1.0"

[[exe]]
name = "myapp"
path = "src/main.fn"
```

- `version` is optional (defaults to `0.0.0`).
- Multiple `[[exe]]` targets are supported (this repository's own
  `fun`/`fls` binaries are a real example).
- A `[lib]` table (one `path`, no name) declares a library entry point
  instead of a binary.
- Only a narrow TOML subset is supported: no nested tables, no arrays of
  scalars, no multi-line or escaped strings, just what a package
  name/version and a flat list of executable targets need.

`fun build` reads `./fun.toml`, compiles every `[[exe]]` target, and
installs the resulting binaries under `fun-out/bin/`. Unlike `fun -in
file.fn`, nothing is run afterward: `fun build` only ever compiles.

## What's next

- **Language**: the full syntax, type system, and control flow.
- **Concurrency**: `async`/`await`, `fork`, and channels.
- **Tooling**: testing, fuzzing, formatting, the language server, editor
  setup, and the full CLI reference.
- **Platforms & Compilers**: C compiler selection, runtime backends, and
  what's supported where.
- **Std Library**: browse every standard library module and its
  documentation interactively.
- **Playground**: try Fun code directly in the browser.
