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
separate `FUN_FUZZ_CC` override instead (see Fuzzing, in Tooling).

### Windows notes

When using `cl`, run Fun from Developer PowerShell for Visual Studio (or
after `VsDevCmd.bat`) so MSVC environment variables are initialized:

```powershell
$env:FUN_CC = "cl /nologo /Fe{out} {src}"
$env:FUN_CC_ARGS = ""
```

`FUN_CC` may also be a full template when it includes `{src}` and
`{out}`, as above, rather than just a bare compiler name.

## Runtime Backend Selection

`std.runtime_backend` selects the runtime backend with this precedence:

1. `FUN_RUNTIME_BACKEND` (`posix`/`windows` or `1`/`2`)
2. `FUN_RUNTIME_OS` (`posix`/`unix`/`windows`)
3. Host hints from environment (`OS`, `OSTYPE`)
4. Fallback to `posix`

`std.thread_runtime` and `std.sync_runtime` follow the same selector.

## Platform & Target Support

Fun has two runtime backends, POSIX and Windows (see Runtime Backend
Selection above), and is built, tested, and released across the
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
platform (see the release matrix below for where aarch64 is covered, as
a release build, not a test).

### Release artifacts

| Target | Runner | Artifact |
|---|---|---|
| Linux x86_64 | `ubuntu-24.04` | tarball + `install.sh` |
| Linux aarch64 | `ubuntu-24.04-arm` | tarball + `install.sh` |
| macOS x86_64 | `macos-13` | tarball + `install.sh` |
| macOS aarch64 | `macos-14` | tarball + `install.sh` |
| Windows x86_64 | `windows-latest` | `.msi` + portable `.zip` |
| Windows aarch64 | `windows-11-arm` | `.msi` + portable `.zip` |

Note the asymmetry: `windows-11-arm` has a release build lane but no
corresponding CI test lane, so Windows-on-ARM release artifacts are
built but not exercised against the test suite before release.

## Arbitrary-width Integers Past 128 Bits, by C Compiler

An arbitrary width up to 128 bits (`i72`, `u100`, and so on) compiles
everywhere: Fun emits the nearest standard container (`int8_t` through
`int64_t`, or `__int128`/`unsigned __int128`), both long-supported
GNU/Clang extensions regardless of platform. See Types, in Language, for
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

- Import C headers via `imp std.c.*;`.
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
