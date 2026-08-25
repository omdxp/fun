<div align="center">
  <img src="editors/vscode/fun.png" alt="Fun Programming Language" width="220" />
  <h1>Fun Programming Language</h1>
  <p>A statically typed programming language that transpiles to C, built for predictable performance, straightforward tooling, and portable deployment.</p>
  <p>
    <a href="https://omdxp.github.io/fun/#language"><strong>Language Guide</strong></a>
    ·
    <a href="https://omdxp.github.io/fun/#reference"><strong>Reference</strong></a>
    ·
    <a href="examples/"><strong>Examples</strong></a>
    ·
    <a href="https://marketplace.visualstudio.com/items?itemName=omdxp.fun-language"><strong>VS Code</strong></a>
  </p>
  <p>
    <a href="https://github.com/omdxp/fun/actions"><img src="https://img.shields.io/github/actions/workflow/status/omdxp/fun/ci-dev.yml?branch=main" alt="CI status" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License" /></a>
  </p>
</div>

## Overview

Fun is a self-hosted compiled language: the compiler is itself written in Fun, and lowers Fun source code to readable C. The project focuses on a compact language surface, strong static typing, practical concurrency, and an editor-friendly toolchain built around formatting, diagnostics, and language-server support.

The language provides high-level default numerics (`num`, `dec`), fixed-width scalar types (`i32`, `u64`, `f32`, `f64`), and arbitrary-width integers (`iN`, `uN`) so the same codebase can target ergonomic application code and lower-level systems work.

## Why Fun

- Predictable compilation model: Fun compiles through C, making generated output inspectable and portable across common platform toolchains.
- Practical type system: the language combines simple defaults with low-level numeric control when exact layout or width matters.
- Built-in concurrency primitives: virtual threads, channels, async/await, and task coordination are first-class parts of the language and standard library.
- Tooling-first workflow: formatting, diagnostics, a language server, and editor integrations are part of the day-to-day development experience.
- Compact standard library: the core library covers collections, filesystem, networking, serialization, synchronization, and C interop signatures.

## Core Capabilities

- Static typing with explicit, readable syntax
- Transpilation to C with debug-friendly source mapping
- Pattern matching via `fit`
- Data-carrying enums and generic compounds
- Default parameter values
- Virtual-thread concurrency with `fork`
- Standard-library support for channels, tasks, threads, filesystem access, JSON, TOML, networking, and more
- CLI tooling for formatting, diagnostics, AST inspection, and code generation

## Installation

### Release Bundles

Release assets are published as install bundles containing the compiler, the standard library under `share/fun/`, and platform-specific install assets.

- Windows releases are available as `.msi` installers and portable `.zip` archives.
- Portable archives preserve the same `bin/` and `share/fun/` layout as an installed release.
- Windows portable packages include `README-portable.txt` with platform-specific startup notes.

At runtime, the compiler discovers the standard library in this order:

1. `FUN_STDLIB_DIR`
2. `<exe>/../share/fun`
3. Common system install locations for the active platform

`std.c.*` modules are signature-only C interop definitions used for typechecking and tooling. `std.*` modules without the `.c` namespace are Fun-native standard library modules.

### Build From Source

With a `fun` binary already on `PATH` (from a release, or a previous build), rebuild the compiler and language server from this repository's own source:

```sh
git clone https://github.com/omdxp/fun.git
cd fun
fun build
```

This reads [fun.toml](fun.toml) and produces `fun`/`fls` under `fun-out/bin/`. Building with nothing installed at all needs a one-time bootstrap step first, see [CONTRIBUTING.md](CONTRIBUTING.md).

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

## CLI

```text
Usage:
  fun -in <input_file> [-fmt | -fmt-all | -fmt-diag | -fmt-check | -fmt-check-all] [-out <output_file>] [-no-exec] [-outf] [-ast] [-g] [-help] [-- <program args...>]
  fun -fmt-check-all [-in <file_or_dir>]
  fun -version
```

Key workflows:

- `fun -in file.fn` compiles and runs a Fun program.
- `fun -fmt`, `fun -fmt-all`, and `fun -fmt-check-all` enforce formatting across a file or tree.
- `fun -fmt-diag -no-exec` formats and collects diagnostics in a single pass.
- `fun -g` emits debug-friendly Fun-to-C source mapping for native debugger workflows.

### C Compiler Selection

By default, `fun` selects a platform compiler unless `FUN_CC` is set.

- macOS and Linux: `clang`, `gcc`, `cc`
- Windows: `clang`, `gcc`, `cl`

You can override the compiler with:

- `FUN_CC`: base compiler command, or a full template when it includes `{src}` and `{out}`
- `FUN_CC_ARGS`: additional arguments appended to the base command

Examples:

- `FUN_CC=clang`
- `FUN_CC="clang -O2 {src} -o {out}"`

#### Windows Notes

When using `cl`, run Fun from **Developer PowerShell for Visual Studio** (or after `VsDevCmd.bat`) so MSVC environment variables are initialized:

```powershell
$env:FUN_CC = "cl /nologo /Fe{out} {src}"
$env:FUN_CC_ARGS = ""
```

## Tooling And Editor Support

The repository includes `fls`, the Fun language server. It communicates over LSP and supports diagnostics, formatting-aware workflows, hover, completion, go-to-definition, and related editor features.

### VS Code

The official VS Code extension is published on the Visual Studio Marketplace: [Fun (FLS) for VS Code](https://marketplace.visualstudio.com/items?itemName=omdxp.fun-language).

1. Build `fun` and `fls` with `fun build`, or install a release bundle.
2. Install the published extension from the marketplace.
3. For local development, packaging, or extension source, see [editors/vscode](editors/vscode).

### Other Editors

Vim, Neovim, Emacs, JetBrains, and Sublime setup notes are available in [editors/README.md](editors/README.md).

### GitHub Syntax Highlighting

This repository maps `.fn` files to Zig highlighting on GitHub via [/.gitattributes](.gitattributes). Native Fun highlighting can be added upstream by contributing a Fun definition and TextMate grammar to GitHub Linguist.

## Documentation

- [Public documentation site](https://omdxp.github.io/fun/): primary documentation entry point
- [Language guide](https://omdxp.github.io/fun/#language): public language overview and feature guide
- [Reference](https://omdxp.github.io/fun/#reference): public language and library reference
- [Interactive playground](https://omdxp.github.io/fun/#playground): runnable browser-based examples
- [docs/architecture.md](docs/architecture.md): implementation structure and compiler pipeline
- [docs/channel-runtime-conformance.md](docs/channel-runtime-conformance.md): backend conformance matrix and runtime thresholds
- [docs/faq.md](docs/faq.md): common questions about the language and tooling
- [docs/](docs/): source Markdown that feeds the published documentation

## Examples

The [examples/](examples/) directory is organized for incremental exploration:

- foundational language examples
- advanced language features and concurrency patterns
- import and module-organization scenarios
- standard-library usage examples
- negative and edge-case programs used for diagnostics and behavior validation

Representative entry points:

- [examples/test.fn](examples/test.fn)
- [examples/advanced/custom_functions.fn](examples/advanced/custom_functions.fn)
- [examples/imports/main.fn](examples/imports/main.fn)
- [examples/stdlib/json_basic.fn](examples/stdlib/json_basic.fn)

## CI And Automation

Use the published setup action to install Fun in GitHub Actions:

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

## Repository Layout

- `src/`: the compiler, language server, and their own test suites, written in Fun
- `stdlib/`: standard library source and documentation
- `examples/`: sample Fun programs
- `docs/`: source Markdown that feeds the published documentation site
- `editors/`: editor integrations and language tooling packages
- `scripts/`: repository validation and packaging scripts

## Contributing

Contribution guidelines, development expectations, and pull-request workflow are documented in [CONTRIBUTING.md](CONTRIBUTING.md).

## Changelog

Release history and notable changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

Fun is released under the MIT License. See [LICENSE](LICENSE) for the full text.







