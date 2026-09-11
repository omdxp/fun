# Tooling

## Testing

```fun
imp std.io;

fun add(num a, num b) num { ret a + b; }

test "add works" {
  assert add(2, 3) == 5, "expected 5";
}

fun main() {
  // Clicking Run here only runs main - an ordinary compile ignores
  // the test block above entirely (see below); use `fun test` to run it.
  println_fmt("add(2, 3)={num}", add(2, 3));
}
```

- **Declaration**: `test "description" { ... }` at the top level (like
  `fun`). The body reuses ordinary statement parsing, so `assert`,
  `panic`, `if`/`for`, etc. all just work inside.
- **Ignored by an ordinary compile**: `fun -in file.fn` never type-checks
  or emits `test` blocks at all, so a test referencing something broken
  doesn't stop the normal program from compiling.
- **Running tests**: `fun test <path>` (shorthand for `fun -in <path>
  -test`) compiles `test` blocks into a runner and runs it. Every
  discovered test runs concurrently (each dispatched onto its own
  virtual task, via the same `fork`/`channel` primitives ordinary Fun
  code uses), printing `test: <name> ... PASS`/`FAIL` as each one
  completes (in completion order, not declaration order) and a `N/N
  tests passed` summary at the end.
- **Filtering to one test**: `fun test <path> --"exact name"` (space
  omitted here only so this line reads as one code span; write it with a
  space in a real shell) runs just the matching test(s) instead of the
  whole file, what an editor's per-test Run/Debug button uses under the
  hood, needing no separate flag.
- **Running every test in a project**: `fun test` (no path) or `fun test
  <dir>` discovers every `.fn` file under that root declaring a `test`
  block, compiles and runs each one in its own pass, and prints an
  aggregate `== <file> ==` header per file plus a final `N/N test files
  passed` summary. `fun test <file.fn>` keeps compiling and running just
  that one file, unchanged.
- **Failure semantics**: a failing `assert` inside a test is caught and
  reported as `FAIL`, it does NOT abort the run, so every other test
  still executes. `panic`, by contrast, still aborts the whole process
  outright (no per-test recovery for it yet), prefer `assert` over
  `panic` inside a test body for this reason.
- **Time-mocked tests**: `imp std.mock_time;` provides a `Clock` quirk
  implemented by `SystemClock` (the real clock) and `MockClock` (a fully
  controllable fake one, for tests). A function that needs "the current
  time" to be testable should accept a `Clock` parameter instead of
  calling `std.time`'s `now()` directly:

```fun
imp std.io;
imp std.mock_time;
imp std.time;

fun is_expired(Clock c, Timestamp issued_at, num ttl_seconds) bin {
  ret diff_seconds(c.now().epoch, issued_at.epoch) >= ttl_seconds;
}

test "a token expires after its ttl" {
  MockClock clk = mock_clock_at(0);
  Timestamp issued = clk.now();
  assert !is_expired(&clk, issued, 60), "should not be expired yet";
  clk.advance(61); // instant, no real waiting
  assert is_expired(&clk, issued, 60), "should be expired now";
}

fun main() {
  MockClock clk = mock_clock_at(0);
  Timestamp issued = clk.now();
  println_fmt("expired at 0s? {bin}", is_expired(&clk, issued, 60));
  clk.advance(61);
  println_fmt("expired at 61s? {bin}", is_expired(&clk, issued, 60));
}
```

A concrete value always coerces to a quirk-typed parameter by its address
(`&clk`), same as any other quirk coercion.

## Fuzzing

```fun
fuzz "parser never crashes on garbage input" (raw* data, num len) {
  parse_bytes(data, len);
}

fun main() {
  // Like a test block, a fuzz block is ignored by an ordinary compile;
  // Run here only runs main. Use `fun fuzz` to actually run the target.
}
```

- **Declaration**: `fuzz "description" (raw* data, num len) { ... }` at
  the top level. Parameters are written out explicitly, like an ordinary
  function's, but the TYPES are fixed by the fuzzing calling convention
  (`data` is always `raw*`, a byte buffer; `len` is always `num`, its
  length), so a declaration with any other shape is rejected.
- **Ignored by an ordinary compile or `fun test` run**: same reasoning as
  `test` blocks, a `fuzz` block is only type-checked/emitted in its own
  compile mode.
- **Running**: `fun fuzz <path> [<target>]` (shorthand for `fun -in
  <path> -fuzz [-fuzz-target <target>]`) compiles the named `fuzz` block
  (or the only one, if a file declares just one) into a single-purpose
  harness and runs it. The harness has no `main` of its own, a
  coverage-guided fuzzing engine's own driver supplies one, generating
  inputs, tracking which code paths each one reaches, and mutating
  toward inputs that explore new behavior. When it finds an input that
  crashes the harness, it saves that input so the crash can be
  reproduced and debugged afterward.
- **A crash is the point**: unlike `test`'s recovered `assert`, an
  `assert` (or a real memory error) inside a `fuzz` block crashes the
  process outright, that's the signal the engine is watching for.
- **Passing flags to the fuzzing engine itself**: everything after the
  `--` separator goes straight through to the compiled harness's own
  argv, the same passthrough every other Fun program already gets, no
  fuzz-specific wiring. This is how you control the engine's behavior (as
  opposed to `-fuzz-target`, which picks which Fun `fuzz` block gets
  built):

```sh
fun fuzz file.fn -- -max_total_time=30   # run for 30 seconds
fun fuzz file.fn -- -runs=10000          # run a fixed number of inputs
fun fuzz file.fn -- -max_len=256         # cap generated input size
fun fuzz file.fn -- corpus/              # persist/seed a corpus directory
```

These flags belong to the underlying engine, not to `fun` itself,
consult its own `-help=1` output (run the compiled harness directly with
that flag) for the full list.

- **Platform/toolchain caveat**: this needs a compiler whose toolchain
  bundles a coverage-guided fuzzing runtime. That's not guaranteed on
  every platform or default compiler install, notably, Xcode's bundled
  clang on macOS does NOT include it. `fun fuzz` tries `clang` first,
  then falls back to a couple of common non-default install locations
  (Homebrew's LLVM on macOS, versioned `clang-N` on Linux since the
  unversioned symlink isn't always installed, the official LLVM
  installer's default path on Windows) before giving up with a clear
  message.
- **`FUN_FUZZ_CC`**: point at a specific compiler if none of the
  automatic candidates work for you. Deliberately a SEPARATE variable
  from `FUN_CC` (the ordinary-build compiler override, see Platforms &
  Compilers), your normal build compiler (gcc, cl, ...) has nothing to do
  with whether it can ALSO do coverage-guided fuzzing, so `fun fuzz`
  never looks at `FUN_CC` at all; the two can safely be different
  compilers without stepping on each other.
- **If it compiles but hangs immediately on running**: some
  restricted/sandboxed/containerized environments hang during
  AddressSanitizer's own startup (its shadow-memory setup), independent
  of Fun or the fuzzing engine entirely. `FUN_FUZZ_NO_ASAN=1` drops just
  the memory-safety-detection half of the sanitizer flag, coverage-guided
  fuzzing still runs and still finds crashes/failed asserts, just without
  ASan's additional detection.
- **Windows is unverified**: everything above has been confirmed working
  on macOS (after the Homebrew-LLVM fallback) and is expected to work
  similarly on Linux, but there is no Windows machine to test on. Plain
  LLVM `clang.exe` (not `clang-cl.exe`, which isn't tried) should in
  principle accept the same flags, but whether the runtime is reliably
  bundled and the result actually runs correctly on Windows is genuinely
  unknown, treat it as "might work," not confirmed.
- **Running every fuzz target in a project**: `fun fuzz` (no path) or
  `fun fuzz <dir>` discovers every `.fn` file under that root declaring
  one or more `fuzz` targets and runs each for a short, bounded budget
  (`FUN_FUZZ_DEFAULT_SECONDS`, default 30s) instead of the open-ended
  campaign a single named target normally gets. This form is for a
  CI-style "did anything regress" sweep, not a real fuzzing session, a
  target that survives its whole budget with nothing found counts as
  clean, exactly like a target that stops early on its own. Because the
  fuzzing engine's own `-max_total_time` flag isn't reliable in every
  environment, the budget is enforced independently: a watchdog
  force-kills a target's process if it's still running when the budget
  elapses, and that alone is never treated as a failure (only an actual
  crash is). A target name only makes sense alongside one specific file,
  so this form never takes one; `fun fuzz <file.fn> [target]` keeps its
  existing open-ended single-target behavior.

## Formatting

- `fun -fmt -in file.fn` formats a file in place.
- `fun -fmt-all -in file.fn` formats local imports too (skips `std.*`).
- `fun -fmt-check-all` checks formatting across a file or tree without
  writing, exits non-zero if anything would change (useful in CI).
- `fun -fmt-diag -no-exec` formats and collects diagnostics in a single
  pass, avoiding two sequential compiler invocations.
- Asm block contents are preserved as raw text.

## The Language Server (`fls`)

`fls` is Fun's language server: diagnostics, formatting-aware workflows,
hover, completion, go-to-definition, and related editor features over
LSP.

- On save with format-on-save enabled, `fls` uses a single `fun -fmt-diag
  -no-exec` subprocess to format the file and collect diagnostics
  simultaneously, avoiding the cost of two sequential compiler
  invocations.
- When format-on-save is disabled, diagnostics use `fun -no-exec` under
  the hood.
- A 1500 ms debounce prevents redundant diagnostic subprocess launches
  when formatting already ran one on the same save event.

## VS Code Debug Experience

- **Run** and **Debug** code lenses appear above every `fun main(`
  declaration.
- **Run** compiles and runs the file in an integrated terminal.
- **Debug** performs a three-step build: `fun -g -no-exec -outf` then the
  C compiler with `-g`/`/Zi` then a native debugger launch.
- `-g` embeds `#line N "file.fn"` directives in the generated C so DWARF
  maps directly to Fun source lines.
- Breakpoints, call stack, and step-through work on `.fn` files without
  any manual configuration.
- Variable types are remapped from C (`int64_t`, `char*`, `bool`, ...) to
  Fun (`num`, `str`, `bin`, ...) via a DAP message tracker.
- Internal C boilerplate frames (`__fun_async_entry_*`, etc.) are marked
  secondary and collapsed in the call stack.
- Temp `.c` and compiled binary files are created in the OS temp
  directory and deleted automatically when the session ends.
- Debugger auto-detection order: `fun.debugger.type` setting, then
  CodeLLDB, then cpptools, then a platform default (CodeLLDB on
  macOS/Linux, cpptools on Windows).
- On Windows: tries `clang-cl` (DWARF, works with CodeLLDB) then `cl.exe`
  (CodeView, works with the cpptools MSVC engine).

## Other Editors

The official VS Code extension is published on the Visual Studio
Marketplace. Vim, Neovim, Emacs, and JetBrains setup notes are available
in `editors/README.md` in the repository.

GitHub Linguist has no native Fun grammar yet, so `.fn` files render as
plain text in the GitHub UI.

## CLI

```text
fun -in <input_file> [-out <output_file>] [-no-exec] [-outf] [-ast] [-g] [-warn-unused] [-warn-unused-lenient] [-D name=value] [-test] [-fuzz] [-fuzz-target <name>] [-help] [-version] [-- <program args>]
fun test <input_file>   (shorthand for `fun -in <input_file> -test`)
fun test [<dir>]        (runs every `test` block under <dir>, default '.'; aggregate summary)
fun fuzz <input_file> [<target>]   (shorthand for `fun -in <input_file> -fuzz [-fuzz-target <target>]`)
fun fuzz [<dir>]        (runs every `fuzz` target under <dir> for FUN_FUZZ_DEFAULT_SECONDS each, default '.'/30s)
fun build                (reads ./fun.toml, installs binaries under fun-out/bin/)
fun init [lib|exe|mix]   (scaffolds fun.toml and src/, default exe, see Get Started)
fun add <name> --git <url> [--path <subfolder>] [--tag <ref> | --branch <ref> | --rev <sha>] [--token-env <VAR>]
                         (adds or updates a [deps] entry in fun.toml, see Get Started)
fun deps update [<name>] (re-resolves tag/branch [deps] entries and rewrites fun.lock)
```

- `-no-exec`/`-outf`/`-out` apply the same way under `-test`/`-fuzz`
  (both the single-file and `test`/`fuzz` subcommand forms) as they do
  for a plain compile: `-no-exec` stops right after writing the C file
  instead of also compiling and running it, `-out` names where it's
  written, and `-outf` (or naming `-out` at all) keeps it afterward
  instead of deleting it once compiled. This is what the VS Code
  extension's own Debug Test command relies on to get just the C file to
  compile and debug itself.
- `-warn-unused`/`-warn-unused-lenient` also apply under `-test`/`-fuzz`,
  both forms.

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `FUN_STDLIB_DIR` | `<exe>/../share/fun`, then a nearby `stdlib/` search, then a system path | Where the compiler looks for the standard library. |
| `FUN_DEPS_CACHE` | `$HOME/.local/share/fun/deps` | Where fetched `[deps]` checkouts are cached, keyed by repo and resolved commit; shared across every project on the machine. |
| `FUN_CC` | `cc` (`cl` on Windows) | Overrides the host C compiler used to build the generated C. |
| `FUN_CC_ARGS` | (none) | Extra space-separated flags appended to every C compiler invocation. |
| `FUN_FUZZ_CC` | `clang` (searched on `PATH` and common package-manager install paths) | Overrides the compiler used for `-fsanitize=fuzzer` builds under `fun fuzz`. |
| `FUN_FUZZ_DEFAULT_SECONDS` | `30` | Per-target wall-clock budget for `fun fuzz [dir]`'s directory-wide form. |
| `FUN_FUZZ_NO_ASAN` | off | Drops AddressSanitizer from fuzz builds (keeps just `-fsanitize=fuzzer`), for sandboxes where ASan's startup hangs. |
| `FUN_DEADLOCK_WATCHDOG_MS` | unarmed | Milliseconds a virtual thread may block before the concurrency runtime's watchdog warns about a likely deadlock. |
| `FUN_DEADLOCK_ABORT` | warn only | When set to `1`, the deadlock watchdog aborts the process instead of just warning. |
| `FUN_SCHED_MAX_WORKERS` | `4096` | Caps how many OS worker threads the virtual-thread scheduler may grow to under load. |
| `FUN_RUNTIME_BACKEND` | auto-detected | Forces the concurrency runtime backend (`posix`/`windows`, or `1`/`2`), mainly for cross-backend testing. |
| `FUN_RUNTIME_OS` | auto-detected | Forces the OS family (`posix`/`unix`/`windows`) the runtime backend detection resolves to. |

## Standard Library, at a Glance

The Std Library tab documents every module interactively; this is a
quick orientation.

- `std.io`: file helpers + `print`/`println`/`print_num`/`print_dec`/
  `print_bin`, plus a `Sink` stream (`Sink.Stdout`/`Stderr`/`Stdin`/
  `File(File)`) with `write`/`try_write`/`flush` and
  `write_to`/`writeln_to` for writing, `read_line_max`/`read_bytes` for
  reading, and a `RotatingSink` (size-capped, generation-rolling file
  logger).
- `std.vec`, `std.map`, `std.set`: dynamic vectors, generic maps
  (`Map<K, V>`), and sets built on maps.
- `std.option`/`std.result`: generic `Option<T>` and `Result<T, E>`
  containers (`ok`/`err`/`err_kind`/`err_error` are fixed to `E = Error`;
  a custom `E` is constructed directly via `ret .Err(CustomKind.Variant);`).
  The postfix `expr?`/`expr!` operators unwrap either one and propagate
  `.None`/`.Err(e)` up automatically; see [Option/Result Propagation](
  language.md#optionresult-propagation).
- `std.collections`: collection quirks (`len`/`is_empty`).
- `std.string`: string helpers.
- `std.channel`/`std.task`/`std.sync`: the concurrency primitives covered
  in [Concurrency](#concurrency).
- `std.runtime_backend`/`std.thread_runtime`/`std.sync_runtime` and their
  `*_backend_posix`/`*_backend_windows` modules: the backend-selection
  machinery covered in [Platforms & Compilers](#platforms).
- `std.json`: typed JSON via the `JsonValue` data enum (`Null`/`Bool`/
  `Num`/`Str`/`Array`/`Object`); `parse(str) -> Result<JsonValue>`,
  Option-returning accessors, and `to_string`/`stringify`.
- `std.toml`: typed TOML via `TomlValue`; `parse_document`, typed
  `get`/`as_int`/`as_float`/`as_str`/`as_bool`, and `stringify`.
- `std.serde`: text-layer `to_string`/`from_string`, dispatching through
  `std.quirks`' generic `To<str>`/`From<str>`.
- `std.log`: structured logging (`LogLevel`, `LogFormat`, a `Logger`
  routed to any `std.io.Sink`, text or one-JSON-object-per-line output).
- `std.quirks`: common quirks, `Sized`, `Display`, `Clearable`,
  `Iterator<T>`, and the generic conversion quirks `To<T>`/`From<T>`.
- `std.time`, `std.rand`, `std.math`, `std.path`, `std.net`, and more.
- `std.mock_time`: `Clock`/`SystemClock`/`MockClock`, see Testing above.
- `std.sys`: environment and process helpers (`env`/`env_or`/`set_env`/
  `clear_env`, `sys_exit`, `sys_abort`, `sys_system`).
- `std.net`: URL parsing and pure Fun POSIX TCP/HTTP helpers.
