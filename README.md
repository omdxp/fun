
# Fun Programming Language

[![CI](https://img.shields.io/github/actions/workflow/status/omdxp/fun/ci-dev.yml?branch=main)](https://github.com/omdxp/fun/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Fun** is a statically-typed programming language that transpiles to C, designed for safety, performance, and simplicity. Written in Zig. Fun includes high-level defaults (`num`, `dec`) and low-level fixed/arbitrary-width numeric types (`i32`, `u64`, `f32`, `f64`, `iN`, `uN`).

---

## Table of Contents
- [Fun Programming Language](#fun-programming-language)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Installation](#installation)
  - [Release installers (bundles)](#release-installers-bundles)
  - [GitHub Actions](#github-actions)
  - [CLI Usage](#cli-usage)
    - [C Compiler Selection](#c-compiler-selection)
      - [Windows notes](#windows-notes)
  - [Quickstart](#quickstart)
  - [Examples](#examples)
  - [Documentation](#documentation)
  - [Project Structure](#project-structure)
  - [Contributing](#contributing)
  - [Changelog](#changelog)
  - [License](#license)
  - [IDE / Language Server (fls)](#ide--language-server-fls)
    - [VS Code](#vs-code)
    - [Other Editors](#other-editors)
    - [GitHub Syntax Highlighting](#github-syntax-highlighting)
  - [Installation](#installation-1)
    - [Prerequisites](#prerequisites)
    - [Build from Source](#build-from-source)
    - [Install from Release](#install-from-release)

---

## Features

- Statically-typed, C-like performance
- Rich numeric model (`num`/`dec`, fixed-width `i32`/`u64`, and arbitrary-width `iN`/`uN`)
- Transpiles to readable C code
- Simple, expressive syntax
- Modular imports
- Pattern matching (`fit` statement)
- Type-safe variables and functions
- Default parameter values (`fun f(num x, num y = 1)`)
- Data-carrying enums (sum types) with payload binding
- Concurrency: virtual threads (`fork`, M:N scheduler), channels, and a `std.task` WaitGroup
- CLI with multiple output and debug options
- AST printing and analysis
- Comprehensive error handling
- Example and test suite

## Installation

Requires [Zig](https://ziglang.org/).

```bash
zig build
```

This will build the `fun` compiler in `zig-out/bin/fun`.

To install the compiler plus the Fun standard library files:

```bash
zig build install
```

This installs:
- `zig-out/bin/fun`
- `zig-out/share/fun/stdlib/std/c/*.fn` (signature-only C-interop modules used for tooling)

Notes:
- `std.c.*` is the C-interop layer (signatures only). These modules describe external C APIs (e.g. `printf`) so the compiler and language server can typecheck and provide tooling.
- `std.*` (without `.c`) is intended for Fun-native standard library modules written in Fun.

## Release installers (bundles)

Release assets are packaged as install bundles (binary + `share/fun/` + an installer script).

On Windows, release assets are provided as both `.msi` installers and portable `.zip` archives.
The portable archive contains the same `fun-<target>/` layout (`bin/` + `share/fun/`) so you can unzip and run without installation.
Each portable archive also includes `README-portable.txt` with Windows-specific quickstart notes.

The compiler discovers the standard library at runtime using, in order:
- `FUN_STDLIB_DIR` (explicit override)
- `<exe>/../share/fun` (installed layout)
- common system locations (platform-dependent)

## GitHub Actions

Use the published setup action to install `fun` in CI:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: omdxp/setup-fun@v1
        with:
          version: latest
      - run: fun -version
```

## CLI Usage

```
Usage:
  fun -in <input_file> [-fmt | -fmt-all | -fmt-diag | -fmt-check | -fmt-check-all] [-out <output_file>] [-no-exec] [-outf] [-ast] [-g] [-help] [-- <program args...>]
  fun -fmt-check-all [-in <file_or_dir>]
  fun -version

Arguments:
  -help             Show this help message
  -version          Print version and exit
  -in      <file>   Input file to compile (required except for -fmt-check-all)
  -fmt              Format the input file in-place (optional)
  -fmt-all          Format the input file and all locally imported modules (optional)
  -fmt-diag         Format the input file in-place, then run diagnostics (optional)
  -fmt-check        Check if the input file is formatted; exit 1 if not (optional)
  -fmt-check-all    Check every .fn file under the current directory or -in root; exit 1 if any are unformatted (optional)
  -g                Enable debug info: source-level Fun→C mapping + DWARF symbols (optional)
  -out     <file>   Output file (optional, defaults to input filename with .c extension)
  -no-exec          Disable automatic compilation and execution (optional, execution enabled by default)
  -outf             Generate .c output file (optional, disabled by default)
  -ast              Print AST nodes (optional, disabled by default)
  --                All following args are passed to the compiled program
```

### C Compiler Selection

By default, `fun` tries platform compiler defaults unless `FUN_CC` is set:

- Windows: `zig cc`, `clang`, `gcc`, `cl`
- macOS/Linux: `zig cc`, `clang`, `gcc`, `cc`

Release installers on macOS/Linux set `FUN_CC=gcc` by default. The Windows MSI sets `FUN_CC` to use `cl` with a template command. The Windows portable `.zip` does not modify your environment. You can override the C compiler with environment variables:

- `FUN_CC`: compiler command. If it includes `{src}` and `{out}`, it is treated as a full template.
- `FUN_CC_ARGS`: extra arguments appended after the base command.

Examples:

- Use clang:
  - `FUN_CC=clang`
- Use zig cc explicitly:
  - `FUN_CC=zig` and `FUN_CC_ARGS="cc"`
- Use a template with explicit placeholders:
  - `FUN_CC="clang -O2 {src} -o {out}"`

#### Windows notes

If you use `cl`, run `fun` from **Developer PowerShell for Visual Studio** (or after `VsDevCmd.bat`) so MSVC environment variables are initialized.

Recommended stable setup on Windows:

```powershell
$env:FUN_CC = "zig"
$env:FUN_CC_ARGS = "cc"
```

Use `cl` explicitly only when your VS toolchain shell is active:

```powershell
$env:FUN_CC = "cl /nologo /Fe{out} {src}"
$env:FUN_CC_ARGS = ""
```

If `cl` compiles but runtime output looks wrong on your system/toolset, switch back to `zig cc`.

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
- Imports (parent traversal `....`): [`imports/parent_traversal_2up/nested/level1/main.fn`](examples/imports/parent_traversal_2up/nested/level1/main.fn)
- Error cases: [`error_cases/`](examples/error_cases/)

## Documentation

- Language overview: [docs/language.md](docs/language.md)
- Full reference: [docs/reference.md](docs/reference.md)
- Channel/runtime conformance matrix and backend thresholds: [docs/channel-runtime-conformance.md](docs/channel-runtime-conformance.md)

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
  - Formatting + diagnostics combined (via `fun -fmt-diag -no-exec`) — when format-on-save is enabled, fls uses a single subprocess to format and collect diagnostics simultaneously, rather than two sequential compiler calls

### VS Code

There is a minimal VS Code extension scaffold in [editors/vscode](editors/vscode).

- Build `fun` + `fls` first (`zig build`)
- Then open `editors/vscode` in VS Code and follow its README.

### Other Editors

See [editors/README.md](editors/README.md) for Vim/Neovim, Emacs, JetBrains, and Sublime setup.

### GitHub Syntax Highlighting

This repo maps `.fn` files to Zig highlighting on GitHub via [/.gitattributes](.gitattributes).
For native Fun highlighting, submit a Fun definition + TextMate grammar to GitHub Linguist.

## Installation

### Prerequisites

- [Zig](https://ziglang.org/download/) (the one defined in [build.zig.zon](build.zig.zon))
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







