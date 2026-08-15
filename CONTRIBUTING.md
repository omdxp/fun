# Contributing to Fun

Thank you for contributing to Fun. This document outlines the expected workflow for code changes, issue reports, and pull requests so contributions can be reviewed and merged efficiently.

## Before You Start

- Review the current [README.md](README.md) and the relevant documentation under [docs/](docs/).
- Search existing issues and pull requests before opening a new report or proposal.
- Prefer focused changes. Small, well-scoped pull requests are easier to validate and review.

## Development Workflow

1. Fork the repository and create a branch from `main`.
2. Make the smallest change that fully addresses the issue or feature.
3. Add or update tests whenever behavior changes.
4. Run the relevant validation commands before opening a pull request.
5. Open a pull request with a clear description of the problem, approach, and validation performed.

## Building From Source

Fun's compiler and language server are themselves written in Fun, under `selfhost/`. Building that from nothing needs a one-time bootstrap: this repository also carries a reference implementation of the compiler (`cmd/`, `modules/`, `tests/`), built with [Zig](https://ziglang.org/download/) (matching the version declared in [build.zig.zon](build.zig.zon)). `zig build` produces a first `fun` binary from that reference implementation; running `fun build` with that binary then reads [fun.toml](fun.toml) and builds the self-hosted `fun`/`fls` from `selfhost/` into `fun-out/bin/`. That self-hosted binary is what actually gets tested and iterated on day to day — the reference implementation exists to bootstrap it and to keep its own test suite (below) green as a safety net.

## Validation Expectations

At minimum, contributors should run the repository validation relevant to the changed area.

- Full reference-implementation validation: `zig build test --summary all`
- Reference-implementation build: `zig build`
- Self-hosted build + test: `zig-out/bin/fun build`, then `fun-out/bin/fun test selfhost/tests`
- Editor extension changes: run the local build steps documented in [editors/vscode/README.md](editors/vscode/README.md)

If a change intentionally affects diagnostics, formatting, runtime backends, or editor tooling, include the commands used to verify that behavior in the pull request description.

## Code And Documentation Standards

- Follow the style already established in the surrounding code.
- Prefer explicit, descriptive names over abbreviated identifiers.
- Keep changes targeted; avoid unrelated refactors in the same pull request.
- Update documentation when user-facing behavior, tooling, or configuration changes.
- Keep examples and README content aligned with the current implementation.

## Reporting Issues

When filing a bug, include enough detail for maintainers to reproduce the problem quickly:

- operating system and toolchain details
- the Fun input or project layout involved
- the exact command executed
- expected behavior
- actual behavior
- relevant logs, diagnostics, or generated output

Feature requests should explain the use case, the limitation in the current behavior, and any constraints that matter for the design.

## Pull Request Guidance

Pull requests should include:

- a concise summary of the change
- the motivation or problem statement
- validation performed
- links to any related issues or prior discussion

If the change affects syntax, diagnostics, standard-library APIs, or editor behavior, call that out explicitly in the PR description so reviewers can route it appropriately.

## Community Expectations

All contributors are expected to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Reviews and discussion should stay technical, respectful, and evidence-based.
