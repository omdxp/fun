# Fun FAQ

## What is Fun designed for?

Fun is a statically typed language that transpiles to C. The project emphasizes readable generated output, predictable deployment across common C toolchains, and a practical development workflow built around formatting, diagnostics, and editor tooling.

## How do I run a Fun program?

See the Quickstart section in the repository [README](../README.md). The standard local workflow is:

```sh
fun -in path/to/file.fn
```

## What numeric types does Fun provide?

`num` and `dec` are 64-bit by default (`int64_t` and `double`). Fun also provides fixed-width scalar types such as `i32`, `u64`, `f32`, and `f64`, plus arbitrary-width integers through `iN` and `uN`.

## Where can I find language and library examples?

The [examples/](../examples/) directory contains language, standard-library, import-structure, and negative-behavior examples. It is the best starting point for concrete usage patterns.

## Where is the authoritative documentation?

Use these documents depending on what you need:

- [get-started.md](get-started.md) for installation, `fun init`, and your first build/run
- [language.md](language.md) for syntax, types, and control flow
- [concurrency.md](concurrency.md) for async/await, `fork`, and channels
- [tooling.md](tooling.md) for testing, fuzzing, formatting, and the CLI
- [platforms.md](platforms.md) for C compiler selection and runtime backends
- [architecture.md](architecture.md) for implementation structure

## How do I contribute?

Contribution workflow, validation expectations, and review guidance are documented in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Why does FLS restart repeatedly with `EPIPE` or `SIGABRT` errors?

That usually indicates that the language server crashed while indexing workspace files. FLS defaults to panic-safe token-only indexing. If parser-heavy indexing was enabled for debugging, disable it by unsetting `FLS_ENABLE_INPROC_PARSE` (or setting it to `0`) and keep `FLS_PARSE_SCOPE=none`.
