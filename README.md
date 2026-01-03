
# Fun Programming Language

[![CI](https://img.shields.io/github/actions/workflow/status/omdxp/fun/ci-dev.yml?branch=main)](https://github.com/omdxp/fun/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Fun** is a statically-typed programming language that transpiles to C, designed for safety, performance, and simplicity. Written in Zig.

---

## Table of Contents
- [fun](#fun)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Installation](#installation)
  - [Release installers (bundles)](#release-installers-bundles)
  - [CLI Usage](#cli-usage)
  - [Quickstart](#quickstart)
  - [Examples](#examples)
  - [Project Structure](#project-structure)
  - [Contributing](#contributing)
  - [Changelog](#changelog)
  - [License](#license)

---

## Features

- Statically-typed, C-like performance
- Transpiles to readable C code
- Simple, expressive syntax
- Modular imports
- Pattern matching (`fit` statement)
- Type-safe variables and functions
- CLI with multiple output and debug options
- AST printing and analysis
- Comprehensive error handling
- Example and test suite

## Installation

Requires [Zig](https://ziglang.org/) (v0.14.0+ recommended).

```bash
zig build
```

This will build the `fun` compiler in `zig-out/bin/fun`.

To install the compiler plus the Fun standard library signature files:

```bash
zig build install
```

This installs:
- `zig-out/bin/fun`
- `zig-out/share/fun/std/*.fn` (signature-only standard library modules for tooling)

## Release installers (bundles)

Release assets are packaged as install bundles (binary + `share/fun/` + an installer script).

On Windows, release assets are provided as `.msi` installers.

The compiler discovers the standard library at runtime using, in order:
- `FUN_STDLIB_DIR` (explicit override)
- `<exe>/../share/fun` (installed layout)
- common system locations (platform-dependent)

## CLI Usage

```
Usage: fun -in <input_file> [-out <output_file>] [-no-exec] [-outf] [-ast] [-help]

Arguments:
  -in      <file>  Input file to compile (required)
  -out     <file>  Output file (optional, defaults to input filename with .c extension)
  -no-exec         Disable automatic compilation and execution (optional, execution enabled by default)
  -outf            Generate .c output file (optional, disabled by default)
  -ast             Print AST nodes (optional, disabled by default)
  -help            Show this help message
```

## Quickstart

Write your first program in `hello.fn`:

```fun
imp std.c.io;

fun main(str[] args) {
    printf("Hello, World!\n");
}
```

Compile and run:

```bash
zig build
./zig-out/bin/fun -in hello.fn
```

## Examples

Explore the [`examples/`](examples/) directory for more:
- Basic: [`test.fn`](examples/test.fn)
- Advanced: [`advanced/custom_functions.fn`](examples/advanced/custom_functions.fn)
- Imports: [`imports/main.fn`](examples/imports/main.fn)
- Error cases: [`error_cases/`](examples/error_cases/)

## Project Structure

- `cmd/` — CLI entrypoint
- `modules/` — Core compiler modules (lexer, parser, codegen, semantics, utils, etc.)
- `examples/` — Example programs
- `tests/` — Test suite
- `build.zig` — Zig build script

## Contributing

Contributions are welcome! Please open issues or pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md) if available.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes and development history.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## IDE / Language Server (fls)

This repo includes a work-in-progress language server called `fls`.

- Build: `zig build` (installs `fls` alongside `fun`)
- The server speaks LSP over stdio and currently supports:
  - Diagnostics (via `fun -no-exec`)
  - Formatting (via `fun -fmt -no-exec`)

### VS Code

There is a minimal VS Code extension scaffold in [editors/vscode](editors/vscode).

- Build `fun` + `fls` first (`zig build`)
- Then open `editors/vscode` in VS Code and follow its README.
---

## Installation

### Prerequisites

- [Zig](https://ziglang.org/download/) (latest stable recommended)
- Windows, Linux, or macOS

### Build from Source

Clone the repository and build using Zig:

```sh
git clone https://github.com/omdxp/fun.git
cd fun
zig build
```

### Install from Release

Pre-built installers and binaries are available for each release. See [Release installers (bundles)](#release-installers-bundles).







