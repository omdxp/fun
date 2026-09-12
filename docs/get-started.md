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
- Multiple `[[exe]]` targets are supported (the Fun compiler's own
  `fun`/`fls` binaries are a real example, built from one manifest).
- A `[lib]` table (one `path`, no name) declares a library entry point:
  `fun build` compiles it to an object file under `fun-out/lib/` instead
  of a linked executable, with no `main` required. This is unrelated to
  sharing code with another project: nothing reads or links against a
  `[lib]` entry automatically, and a repo doesn't need one at all for
  `[deps]` below to pull source from it. `[lib]` is about what one
  project's own `fun build` produces; `[deps]` is about pulling another
  project's source in.
- Only a narrow TOML subset is supported: no multi-line or escaped
  strings, and nested tables only in the one-level inline-table form
  `[deps]` entries use below (`key = { a = "x", b = "y" }`); nothing
  deeper.

`fun build` reads `./fun.toml`, compiles every `[[exe]]` target, and
installs the resulting binaries under `fun-out/bin/`. Unlike `fun -in
file.fn`, nothing is run afterward: `fun build` only ever compiles.

### `PACKAGE_NAME` and `PACKAGE_VERSION`

`fun build` (and `fun -in`/`fun test`/`fun fuzz` when a `fun.toml` is
present) makes the manifest's own `[package]` `name` and `version`
available inside the program itself, as two ordinary string constants:

```fun
imp std.io;

fun main() {
  println(format("{str} v{str}", PACKAGE_NAME, PACKAGE_VERSION));
}
```

Neither is declared anywhere in source; the build injects them ahead
of the program's own declarations before type-checking. This is how
`fun`/`fls` themselves report a real version for `-version` without
reading `fun.toml` at runtime. `fls` mirrors this for hover, completion,
and go-to-definition too, so both names resolve and jump straight to
the manifest's own `name`/`version` line like any other declared
constant would.

## Dependencies (`[deps]`)

Fun shares libraries straight from git, no central package index to run
or trust. Add a dependency and use it:

```sh
fun add somejson -git https://github.com/user/somejson -tag v1.2.3
```

```fun
imp deps.somejson.parser;
```

That writes a `[deps]` table in `fun.toml`, one inline table per
dependency, keyed by the name used in `imp deps.<name>...`:

```toml
[deps]
somejson = { git = "https://github.com/user/somejson", tag = "v1.2.3" }
httpclient = { git = "https://github.com/other/repo", path = "libs/httpclient", branch = "main" }
privatelib = { git = "git@github.com:org/private-repo.git", tag = "latest", token_env = "GITHUB_TOKEN" }
```

- `git` is required; everything else is optional.
- `path` points at a subfolder inside the repo that itself acts as the
  dependency root, so a library doesn't need to live at the repo's own
  root, and the repo owner doesn't need to cooperate or declare
  anything special for that subfolder to work. This is a real gap in
  Go modules (one module per repo, or per-directory `go.mod` files the
  owner must add) and in D/dub (`subPackages` the owner must declare in
  `dub.json`) that this design avoids entirely: any subfolder of any
  repo just works, decided entirely by the consumer's own manifest.
- Exactly one of `tag`, `branch`, or `rev` pins what's fetched. Omitting
  all three defaults to the highest semver-sorted tag, or the remote's
  default branch if it has no tags. `tag = "latest"` is equivalent to
  omitting it, spelled out for clarity.
- `token_env` names an environment variable holding a git credential
  for that one remote (a personal access token, for a private repo);
  the value is never written into `fun.toml`, `fun.lock`, or the
  checkout's own git config, and is passed to `git` only as a one-shot
  header on that fetch.

Fetching shells out to the system `git`, so private repos work exactly
the way `git clone` already works for you: an SSH key in your agent for
`git@...` URLs, a credential helper for `https://...`, or `token_env`
for CI. There is no separate "registry" to authenticate against.

`fun build`/`test`/`fuzz` resolve and fetch any `[deps]` entry not
already cached automatically, the same as `cargo build`/`go build`, no
separate install step. Fetched checkouts are cached once per machine
under `$FUN_DEPS_CACHE` (default `$HOME/.local/share/fun/deps`), keyed
by repo and resolved commit, shared across every project that pins the
same commit.

Fetching never checks whether the repo is actually a Fun project, or
that `path` points at anything real: `imp` is already path-based with
no manifest involved, so a `[deps]` entry just clones the ref and lets
the ordinary `imp` machinery find (or fail to find) files under it. A
wrong `path`, or a repo with no Fun code at all, fetches successfully
and only surfaces as a normal "import not found" error at the `imp
deps.<name>...` line that needed it, naming the missing file.

### Transitive dependencies

A fetched dependency that has its own `fun.toml` with its own `[deps]`
gets those resolved too, automatically, flattened into your project's
own `fun.lock` and the same flat `imp deps.<name>...` namespace - `imp
deps.<name>` works for a transitive dependency exactly the way it works
for one you declared yourself. A `git`/`path`/spec conflict two
different sources have for the same name is caught for real: identical
declared pins (or pins that happen to resolve to the exact same commit)
dedupe silently, but two sources genuinely pinning different commits of
the same name is a hard build error naming both. Your project's own
`[deps]` always wins a same-name claim from somewhere deeper in the
graph, silently, no error - the fix for any transitive conflict is
adding your own `[deps]` entry for that name to pick a version yourself.

`fun build` prints one line per dependency actually fetched or updated
(nothing at all when everything's already cached, matching a warm
`cargo build`/`go build`), including which dependency pulled in a
transitive one, so a slow first build is never silent about what it's
doing.

### `fun.lock`

Resolving a `tag`/`branch` writes the exact commit it resolved to into
`fun.lock`, alongside the manifest:

```toml
[deps]
somejson = { git = "https://github.com/user/somejson", path = "", spec = "tag:v1.2.3", resolved_rev = "a1b2c3d4e5f6..." }
```

`resolved_rev` is what every build actually checks out, not `tag`/
`branch` read fresh each time: a `tag`/`branch` entry only re-resolves
on an explicit `fun deps update`, never implicitly, so nobody who
doesn't control your lockfile can silently swap out an already-locked
dependency's content. A `rev`-pinned entry never re-resolves, matching
the same guarantee a commit SHA already gives on its own.

```sh
fun deps update            # re-resolve every tag/branch entry
fun deps update somejson   # re-resolve just one
```

Commit `fun.lock` for a binary project, the same way you'd commit
`Cargo.lock`; a library may leave that choice to whatever consumes it.

### Security

- Every `git` invocation goes through an argv array (never a shell), so
  classic shell-metacharacter injection is structurally impossible; `fun
  add`/manifest parsing still reject a `tag`/`branch`/`rev`/`name` value
  that looks like a flag (starts with `-`) or contains `..`, since a
  crafted ref value passed straight into `git clone --branch <ref>` is a
  known real attack against the git CLI itself.
- `path` is validated to never escape the checkout: no `../`, no leading
  `/`, no backslashes.
- `git` URLs are restricted to `https://`, `ssh://`/`git@`, and
  `file://`; anything else (`ext::`, `fd::`, and similar transport
  helpers with a history of local command execution via a crafted "URL")
  is rejected.
- A fetched dependency is source text, parsed and compiled the same as
  any other `imp`. There is no build-script/install-hook concept at
  all, so a dependency never runs arbitrary code as a side effect of
  being fetched, unlike npm lifecycle scripts or Cargo's `build.rs`.
- A git-based system has no central review or yank mechanism the way a
  hosted registry can. `fun.lock`'s pinned `resolved_rev` is the actual
  defense against a dependency's content silently changing out from
  under you; it does not vet the content itself.

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
