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

Fun's compiler and language server are themselves written in Fun, under `compiler/`. Building them needs an existing `fun` binary to run the build with: install one from a [release bundle](README.md#installation) or [`omdxp/setup-fun`](https://github.com/omdxp/setup-fun), then run:

```sh
fun build
```

This reads [fun.toml](fun.toml) and builds `fun`/`fls` from `compiler/` into `fun-out/bin/`. That freshly built binary is what actually gets tested and iterated on day to day.

## Validation Expectations

At minimum, contributors should run the repository validation relevant to the changed area.

- Build: `fun build`
- Test suite: `fun-out/bin/fun test compiler/tests`
- Examples corpus: `FUN_EXE=fun-out/bin/fun ./scripts/run_examples.sh`
- Formatting: `fun -fmt-check-all`
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
