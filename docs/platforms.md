# Platforms & Compilers

## C Compiler Selection

By default, `fun` tries `clang`, then `gcc`, then the platform's default
`cc` (`cl` on Windows), using the first one it finds on `PATH`. A
candidate that's found but fails to compile stops the search there
rather than falling through to the next one, since a real compile error
is never solved by switching compilers. You can override the compiler
with environment variables:

- `FUN_CC`: the exact compiler command to use, in place of the search
  above.
- `FUN_CC_ARGS`: extra arguments appended after the usual defaults,
  space-separated.

Examples:

- `FUN_CC=clang`
- `FUN_CC=cl` (MSVC, on Windows)
- `FUN_CC=gcc FUN_CC_ARGS="-O2 -Wall"`

`fun fuzz` does NOT use `FUN_CC`/`FUN_CC_ARGS`, it needs a compiler whose
toolchain bundles a coverage-guided fuzzing runtime specifically, which
has nothing to do with your ordinary build compiler, so it has its own
separate `FUN_FUZZ_CC` override instead (see [Fuzzing](#tooling?anchor=tooling-fuzzing), in Tooling).

### Windows notes

Fun automatically detects and sources the MSVC build environment on
Windows. You can run `fun -in`, `fun build`, and `fun test` from any
ordinary PowerShell or CMD terminal — no Developer Command Prompt, no
manual `VsDevCmd.bat`, no `FUN_CC` override needed.

Specifically: if the `INCLUDE` environment variable is not set, Fun
locates your Visual Studio installation via `vswhere.exe` (at its
standard path under `Program Files (x86)\Microsoft Visual Studio\Installer`)
and applies the x64 MSVC environment to the current process before
invoking `cl.exe`. This is a one-time cost on the first compile in a
given terminal session; subsequent compiles in the same session skip it.

If you do need to override the compiler (e.g., to use Clang explicitly),
`FUN_CC` still works as described above.

### Stack size

Every compiled program's `main()` runs on a worker thread given an
explicit 128 MB stack, uniformly on every platform, rather than on
whatever the OS hands the process's own initial thread. This is deliberate,
not incidental: Windows bakes the main thread's own stack reserve into the
EXE's PE header at link time, with no way to grow it after the process has
already started, unlike POSIX, which lets any thread you spawn yourself be
given an explicit size at the moment you create it. Running the real
program body on a worker thread instead sidesteps that platform difference
entirely, and gives deep recursion the same headroom on every target.
`fork`/`await`'s own worker threads use a separate, smaller stack; see
[Concurrency](#concurrency).

### WebAssembly target

Set `FUN_CC=emcc` (or `em++`) to target WebAssembly instead of a native
executable - the [emscripten](https://emscripten.org/) toolchain must
already be on `PATH`. `fun -in`, `fun build`, and `fun test` all work the
same way as any other target: the output is a `.js` glue file plus a
`.wasm` binary (`fun -in` runs it afterward too, the same as a native
build, via `node`).

```
FUN_CC=emcc fun -in hello.fn
```

Most of the language and stdlib works unmodified: file I/O runs against
emscripten's own in-memory filesystem (real for the length of that one
run, not persisted across runs), and `Atomic<T>`, `Guarded<T>`, and
`fork`/`async`/`Channel` (the scheduler's own worker pool) all work.
`std.net` and `std.process` do not - both are rejected at compile time
with a clear message naming the unsupported module, rather than failing
later in a confusing way.

`main()` calls straight through for this target with no worker thread at
all, unlike the stack-sizing approach described above: a browser's own
main (document) thread must never block synchronously on `pthread_join`
the way that approach otherwise relies on everywhere else, so the wasm
module's stack is instead sized directly at compile time
(`-sSTACK_SIZE`). Verified working both under Node and embedded in a real
browser page - see this project's own [reference
website](https://omdxp.github.io/fun/), whose docs examples run this way
client-side, with no backend server at all.

This makes Fun **programs** able to target WebAssembly - the compiler's
own pipeline still ordinarily needs a native C compiler to finish a
build, which a plain browser sandbox can never provide on its own. The
reference website's own Interactive Playground closes that gap for
arbitrary, freshly-typed code anyway, without a dedicated WebAssembly
codegen backend: see "The in-browser Playground" below for how.

### The in-browser Playground

The reference website's [Interactive
Playground](https://omdxp.github.io/fun/) runs arbitrary, edited code
entirely client-side, no backend server involved, by running the
*compiler itself* as two separate WebAssembly modules in the browser:

1. A minimal build of the compiler's own frontend (lex, parse,
   typecheck, codegen-to-C - stops there, never invokes a real C
   compiler itself) runs first, lowering the typed source to C.
2. A real C compiler, itself compiled to WebAssembly and running in
   the same page ([`@wasmer/sdk`](https://docs.wasmer.io/runtime/js)'s
   `clang/clang` package - genuine clang, lld, and wasm-ld, targeting
   wasm32-wasi), compiles that C and runs the result.

Both pieces are real, general-purpose builds, not special-cased for
this one use - the first is the same `FUN_CC=emcc` target described
above, applied to the compiler's own source; the second is an ordinary
C compiler that happens to run as wasm. The second module is large
(~105 MB) and fetched lazily, well before any click needs it (the page
starts warming both wasm modules once it's idle), and cached for the
rest of that page session.

The Playground is a real multi-file project, not a single text box: a
file tree in the sidebar holds every file, any one of them can be the
entry point, and `use`-ing a sibling file resolves exactly as it would
on disk - every project file is mounted into the compile frontend's own
virtual filesystem at its real path before each run.

A third wasm module, built from `src/fls/wasm_fls_main.fn`, drives
real fls diagnostics as the active file is edited (debounced, not on
every keystroke). It is deliberately *not* the same long-running
server a real editor keeps alive over stdio: that would need the
built-in emscripten runtime to stay resident across calls (every wasm
build this project produces tears its runtime down when `main`
returns, exactly so a run-once CLI-style program still prints its
output) and a way to call a function other than `main` from JavaScript,
neither of which exists yet for any target. Each keystroke instead
reloads the module fresh, writes one `textDocument/didOpen` into it,
and reads back the one `textDocument/publishDiagnostics` notification
`Server.opened` always answers it with - simpler and correct, at the
cost of re-parsing the whole project (plus the stdlib) from scratch
every time, with none of `Server`'s own incremental caching ever
getting to help. A persistent, repeatedly-callable module (real
caching, hover, completion, go-to-definition) is a materially bigger
project - genuinely new build-pipeline support, not an extension of
this one - and stays out of scope here.

This is also why `_preload_and_collect_source`'s parallel import
preloading (`fork`ing a fixed worker pool to read a program's import
graph concurrently) has a sequential fallback: a browser only grants
real multi-threading (`SharedArrayBuffer`) with cross-origin-isolation
response headers, which a compiler embedded as a library inside someone
else's page has no way to require. Without the fallback, the parallel
path doesn't error under those conditions, it hangs - every worker's
own `pthread_create` fails, and the scheduler has no way to know.

The same cross-origin-isolation gap shows up once more, separately, and
here it is not harmless: the Wasmer SDK refuses outright to run a
package on a page that is not cross-origin-isolated. Confirmed
directly: without those headers, `window.crossOriginIsolated` is
false and the SDK throws rather than just losing an optimization.
Since GitHub Pages serves static files only and cannot set response
headers, the site ships [`coi-serviceworker.js`](https://github.com/omdxp/fun/blob/main/website/reference/public/coi-serviceworker.js) -
a service worker that intercepts every same-origin fetch and adds
`Cross-Origin-Embedder-Policy: require-corp` and
`Cross-Origin-Opener-Policy: same-origin` to the response client-side.
A freshly installed service worker does not control the page that
registered it until the next navigation, so first-time visitors see
one automatic reload before the Playground becomes usable.

## Runtime Backend Selection

`std.runtime_backend` selects the runtime backend with this precedence:

1. `FUN_RUNTIME_BACKEND` (`posix`/`windows` or `1`/`2`)
2. `FUN_RUNTIME_OS` (`posix`/`unix`/`windows`)
3. Host hints from environment (`OS`, `OSTYPE`)
4. Fallback to `posix`

`std.thread_runtime` and `std.sync_runtime` follow the same selector.

## Platform & Target Support

Fun has two runtime backends, POSIX and Windows (see [Runtime Backend
Selection](#platforms?anchor=platforms-runtime-backend-selection) above), and is built, tested, and released across the
following platforms.

### Runtime backends

| Backend | Covers |
|---|---|
| POSIX (`RUNTIME_BACKEND_POSIX_ID`) | Linux (x86_64, aarch64), macOS (x86_64, aarch64) |
| Windows (`RUNTIME_BACKEND_WINDOWS_ID`) | Windows (x86_64, aarch64) |

### CI (every push and pull request to `main`)

| Platform | Runner | Compiler, stdlib, and examples tested |
|---|---|---|
| Linux | `ubuntu-latest` | Yes |
| macOS | `macos-latest` | Yes |
| Windows | `windows-latest` | Yes |

CI runs on x86_64 runners only; there is no aarch64 CI test lane for any
platform (see the [release matrix](#platforms?anchor=platforms-release-artifacts) below for where aarch64 is covered, as
a release build, not a test).

### Release artifacts

| Target | Runner | Artifact |
|---|---|---|
| Linux x86_64 | `ubuntu-24.04` | tarball + `install.sh` |
| Linux aarch64 | `ubuntu-24.04-arm` | tarball + `install.sh` |
| macOS x86_64 | `macos-15-intel` | tarball + `install.sh` |
| macOS aarch64 | `macos-15` | tarball + `install.sh` |
| Windows x86_64 | `windows-latest` | `.msi` + portable `.zip` |
| Windows aarch64 | `windows-11-arm` | `.msi` + portable `.zip` |

Note the asymmetry: `windows-11-arm` has a release build lane but no
corresponding CI test lane, so Windows-on-ARM release artifacts are
built but not exercised against the test suite before release.

## Arbitrary-width Integers Past 128 Bits, by C Compiler

An arbitrary width up to 128 bits (`i72`, `u100`, and so on) compiles
everywhere: Fun emits the nearest standard container (`int8_t` through
`int64_t`, or `__int128`/`unsigned __int128`), both long-supported
GNU/Clang extensions regardless of platform. See [Types](#language?anchor=language-types), in Language, for
the full numeric type table.

A width past 128 bits, rare in practice (`u256` being the one example in
this repository), needs C23's `_BitInt(N)`, whose compiler support
genuinely varies:

| Compiler | Support past 128 bits |
|---|---|
| GCC 14+ | Yes |
| GCC 13.x (Ubuntu's default, `ubuntu-latest`) | No, `_BitInt` isn't recognized as a keyword at all, under any `-std` |
| Apple Clang | No, capped at 128 bits regardless of the width requested |
| Mainline LLVM Clang | No, same 128-bit cap as Apple Clang |

If a program genuinely needs an integer wider than 128 bits, use
`FUN_CC` to select a compiler that supports it.

## C Interop

- Import C headers via `use std.c.*;`.
- C constants (`NULL`, `INT_MAX`, etc.) are allowed once the right header
  is imported.
- `num` maps to `int64_t`; for `printf`, use `PRId64` (from
  `<inttypes.h>`) or cast to `long long` and use `%lld`.
- Fun stdlib modules under `std.c.*` only declare signatures, the system
  C toolchain provides the implementations, so behavior for a given
  header ultimately follows that platform's own libc/runtime.

## Deadlock Watchdog (opt-in)

Concurrent programs (`fork` and/or channels) can opt into a runtime
deadlock watchdog via environment variables. It is OFF by default: with
the variable unset the runtime is byte-identical, no watchdog thread, no
timed waits, no overhead.

- `FUN_DEADLOCK_WATCHDOG_MS=<ms>`: arm the watchdog with a stall
  threshold in milliseconds. When outstanding work exists but no
  scheduler progress happens and at least one task is parked in a
  blocking channel wait for the whole window, the runtime prints `fun:
  possible deadlock: <n> blocked, <n> pending, no progress for <ms>ms` to
  stderr and keeps running (warn-and-continue; semantics unchanged).
- `FUN_DEADLOCK_ABORT=1`: in addition, `abort()` the process on
  detection (nonzero exit + the diagnostic), for CI/fail-fast use.

The watchdog is a diagnostic aid; it never changes the behavior of a
correct program. Choose a threshold comfortably above your longest
legitimate blocking wait to avoid warning on slow-but-live operations.
