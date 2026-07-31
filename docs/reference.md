# Fun Language Reference (Comprehensive)

## Overview
Fun is a statically-typed, C-transpiling language focused on performance and clarity. The compiler emits readable C and relies on the system C toolchain for linking and execution.

## Numeric Model
- `num` is a signed 64-bit integer (C `int64_t`).
- `dec` is a 64-bit floating-point number (C `double`).
- Fixed-width integers: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`.
- Fixed-width floats: `f32` (`float`), `f64` (`double`).
- Arbitrary-width integers: `iN` / `uN` (emitted as `_BitInt(N)` / `unsigned _BitInt(N)` when width is not a standard 8/16/32/64).
- `bin` is boolean (`bool`).
- `chr` is a character (`char`).
- `str` is a null-terminated string (`char*`).
- `raw` is an opaque/void type (`void` in C; use `raw*` for `void*`).

## Source Structure
- **File extension**: `.fn`
- **Statements** end with `;`.
- **Blocks** are delimited with `{}`.
- **Comments**: `//` single-line.

### Documentation Comments
- The website reference uses regular `//` comments that appear immediately above declarations.
- This applies to module summaries, public symbols, compound fields, and quirk members.
- For best results, keep comments short and declaration-specific.
- Example:

```fun
// Optional value container.
pub compound Option<T> {
  // True when a value is present.
  bin has;
  // Stored value.
  T value;
}

// Value that can render itself as text.
pub quirk Display {
  // Produce a textual representation.
  to_string() str;
}
```

## Imports
- `imp std.c.io;` imports a C header signature module.
- `imp std.string;` imports Fun stdlib modules.
- Relative imports are supported (e.g., `imp ..foo.bar;`).
- Import aliases are supported: `imp mod1 as one;` then use `one.symbol`.
- Aliases are the supported way to avoid duplicate exported symbol collisions across imported modules.
  - Example:
    - `imp mod1 as one;`
    - `imp mod2 as two;`
    - `num a = one.pick();`
    - `num b = two.pick();`

## Types
### Built-in Types
- `num`, `dec`, `f32`, `f64`, `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `iN`, `uN`, `bin`, `chr`, `str`, `raw`

### Raw Strings
A backtick-delimited literal (`` `...` ``) needs no escaping at all: a backslash
or an embedded double-quote is just a literal byte.
```fun
let path = `C:\Users\name\file.txt`;
let msg = `she said "hi" and left`;
```

Two forms, both starting with a backtick, disambiguated purely by whether you
close it on the same line:
- **Inline**: closed by another backtick on the same line (as above).
- **Multi-line**: a backtick left unclosed before the line's newline starts a
  block. Each subsequent line that begins (after leading whitespace) with its
  own backtick contributes its own content, joined with a real newline byte,
  ending at the first line that doesn't:
  ```fun
  let sql =
    `SELECT *
    `FROM users
    `WHERE id = ?
  ;
  ```
  Trailing code that needs to sit on the same line as the last content line
  can close the block explicitly instead: `` `WHERE id = ?`; ``.

A literal backtick inside a raw string still needs to be avoided (there's no
escape for it) -- use a regular `"..."` string for that rare case instead.

### Arrays
- Syntax: `num[] arr = [1, 2, 3];`
- Array literals require uniform element types.

### Pointers
- Pointer depth: `Type*`.
- Example: `Node* next;`.

### Compounds (Structs)
```fun
compound Point {
  num x;
  num y;
}

fun main() {
  Point p;
  p.x = 1;
  p.y = 2;
}
```

A field whose name begins with `_` is **module-private**: it is accessible only
from code in the same module as the compound's declaration (including the type's
own `impl` methods via `self._field`). Other modules must use public accessors.
```fun
compound Account {
  num id;          // public
  num _balance;    // private to this module
}
impl Account {
  pub balance() num { ret self._balance; }   // ok: same module
}
// Another module: `acc._balance` is rejected; `acc.balance()` works.
```

### Quirks (Interfaces)
```fun
quirk Shape {
  area() num;
}

compound Square {
  num side;
}

impl Square as Shape {
  area() num { ret self.side * self.side; }
}

fun main() {
  Square s;
  s.side = 4;
  num area = s.area();
  _ = area;
}
```

Notes:
- Quirk methods obey visibility: private methods are callable inside the same module only.
- `print_fmt("{}", value)` uses `Display.to_string()` when that method is accessible at the call site.
- If `Display.to_string()` exists but is private from the caller module, `{}` falls back to pointer-style formatting.

### Implementations
```fun
quirk Shape {
  area() num;
}

compound Point {
  num x;
  num y;
}

compound Rectangle {
  num w;
  num h;
}

impl Point {
  translate(num dx, num dy) {
    self.x += dx;
    self.y += dy;
  }
}

impl Rectangle as Shape {
  area() num { ret self.w * self.h; }
}

fun main() {
  Point p;
  p.x = 1;
  p.y = 2;
  p.translate(3, 4);

  Rectangle r;
  r.w = 3;
  r.h = 4;
  num area = r.area();
  _ = area;
}
```

### Generics
- Compounds, impls, and free functions can be generic: `compound Vec<T> { ... }`, `fun identity<T>(T x) T { ret x; }`.
- Use `Vec<num>` etc. where required.
- Type parameters can be constrained with `:` and `|` — on impls, compounds, and free functions alike.
  - Examples: `impl Vec<T: num | dec> { ... }`, `compound Box<T: num | str> { T value; }`, `fun identity<T: num | str>(T x) T { ret x; }`.
  - This lets one body work for a fixed set of concrete types; the compiler monomorphizes each concrete instantiation and rejects a call/instantiation whose type argument isn't in the declared bound at compile time.

```fun
compound Vec<T> {
  T[] data;
  num len;
}

impl Vec<T: num | dec> {
  pub sum() T {
    T out = self.zero_value();
    num i = 0;
    for i < self.len {
      out = out + self.data[i];
      i = i + 1;
    }
    ret out;
  }
}

compound Box<T: num | str> {
  T value;
}

fun identity<T: num | str>(T x) T {
  ret x;
}
```

### Generic Quirks
- A quirk can be generic too: `quirk To<T> { to() T; }` — `impl Point as To<JsonValue> { pub to() JsonValue { ... } }` binds a concrete instantiation.
- A concrete instantiation dispatches the same way a non-generic quirk does, in two forms:
  - Direct method call on a value whose type implements it: `p.to()`.
  - A quirk-typed parameter or variable naming the SAME concrete instantiation: `fun to_json_value(To<JsonValue> value) JsonValue { ret value.to(); }`, called as `to_json_value(&p)` for any `p` whose type implements `To<JsonValue>` — the concrete pointer coerces to the quirk-typed parameter at the call site, same as a non-generic quirk.
- Each concrete instantiation (`To<JsonValue>`, `To<num>`, ...) is its own quirk identity: an `impl` binds one specific instantiation, and a quirk-typed parameter/variable must name that same instantiation to dispatch.
- A quirk parameter still needs its argument's TYPE PARAMETER bound to a concrete type (`To<JsonValue>`, not bare `To<T>`) — a still-generic reference to a quirk's own type parameter (`impl VecIter<T> as Iterator<T>`) is a different, SYMBOLIC binding that resolves through the enclosing type's own generic instantiation instead.

## Variables
- Variables can be explicitly typed or inferred with `let`.
```fun
fun add(num a, num b) num {
  ret a + b;
}

fun main() {
  num x = 1;
  str name = "fun";
  let count = add(1, 2);
  _ = x;
  _ = name;
  _ = count;
}
```

### Type Inference (let)
- `let` requires an initializer; the type is inferred from the expression.
- Literal inference:
  - `1` -> `num`, `1.5` -> `dec`, `"text"` -> `str`, `'a'` -> `chr`, `true` -> `bin`.
- Array literals infer element type and become `T[]`:
  - `[1, 2, 3]` -> `num[]`
  - `[Point{x = 1, y = 2}]` -> `Point[]`
- Function calls infer the return type:
  - `let p = make_point(1, 2);` -> `Point`
- Member access uses the receiver's type:
  - `let x = p.x;` -> `num`
- Indexing an array yields its element type:
  - `let v = nums[i];` -> `num` when `nums` is `num[]`
  - `let x = points[0].x;` -> `num` when `points` is `Point[]`
- Numeric expressions prefer `dec` when any operand is `dec` (otherwise `num`).

```fun
compound Point { num x; num y; }

fun make_point(num x, num y) Point {
  ret Point{x = x, y = y};
}

fun main() {
  let n = 42;                // num
  let d = 3.5;               // dec
  let s = "hello";           // str
  let c = 'Z';               // chr
  let b = true;              // bin
  let nums = [1, 2, 3];      // num[]
  let p = make_point(1, 2);  // Point
  let x = p.x;               // num
  let px = nums[0];          // num
}
```

### Constants
- `const` declares an immutable binding, at either top level or local (function-body) scope: `const MAX = 10;` (type inferred, same rules as `let`) or `const num MAX = 10;` (explicit type). Both forms require an initializer.
- `pub const` exports a top-level constant, same as `pub num`/`pub let` for ordinary globals.
- Reassigning a `const` (including via `+=`/`-=`/etc.) is a compile-time error, caught at typecheck for both local and global constants:
```fun
const num MAX = 100;

fun main() {
  const local_max = MAX;
  MAX = 200;       // error: cannot assign to const 'MAX'
  local_max += 1;   // error: cannot assign to const 'local_max'
}
```

## Functions
```fun
fun add(num a, num b) num {
  ret a + b;
}

fun main() {
  num total = add(1, 2);
  _ = total;
}
```
- No nested function declarations.
- Use `ret` for return.
- Generic functions are supported:
```fun
fun id<T>(T x) T { ret x; }

fun main() {
  num v = id(1);
  _ = v;
}
```
- **Default parameter values**: parameters may have defaults (`= expr`); a call may omit
  trailing defaulted arguments.
```fun
fun connect(str host, num port = 8080, bin tls = false) {
  // implementation
}

fun main() {
  connect("a");            // port 8080, tls false
  connect("a", 9000);      // tls false
  connect("a", 9000, true);
}
```
- Rules: defaults must be **trailing** (no required param after a defaulted one); a
  default expression is evaluated at the **call site**, so it cannot reference `self` or
  an earlier parameter (`nil`, literals, globals, and enum variants are fine). Applies to
  free functions and methods, including generic, `async`, and pointer-receiver methods.
- A non-`void` function that can fall off the end without returning triggers the
  `missing_return` warning (always checked; conservative — trailing `ret`, exhaustive
  `if/elif/else`, default-branch `fit`, and infinite loops all count as returning).

## Async / Await
- Declare async functions with `async fun`.
- `await` is only valid inside `async fun` bodies.
- Calls to async functions and async quirk methods must be awaited.
- Await targets must resolve to async calls.

```fun
compound Counter {
  num base;
}

quirk AsyncCounter {
  async add(num x) num;
}

impl Counter as AsyncCounter {
  async add(num x) num { ret self.base + x; }
}

async fun main() {
  Counter c;
  c.base = 41;
  num out = await c.add(1);
  _ = out;
}
```

## Concurrency: `fork` & channels
- `fork <async-call>;` spawns a **virtual thread** (fire-and-forget) onto an M:N
  scheduler — a CPU-count-sized pool of OS worker threads runs many cheap tasks.
- `main` automatically waits for all `fork`ed tasks to finish before returning.
- Channel operators (sugar over `std.channel`):
  - `ch <- v` ≡ `ch.send(v)` (send)
  - `<-ch` ≡ `ch.recv()` (receive; lossy — use `ch.recv_into(&out)` for errors)
- `<-` is the glued two-character operator; `a < -b` (with a space) is still a
  comparison against a negation.
- **Result-style send/recv**: `ch.recv_result()` returns `RecvResult<T>`
  (`Ok(T)`/`Closed`/`Timeout`/`Cancelled`/`Error(num)`) and `ch.send_result(v)` returns
  `SendResult` (`Ok`/`Closed`/`Full`/`Cancelled`/`Error(num)`) — `fit` on them instead of
  decoding a numeric status. Timeout/token and `try_*`/`*_async` variants exist for both.
- **`std.task` WaitGroup**: `wait_group_new(n)` + `wg.done()` in each task + `wg.wait()`
  blocks until all `n` `fork`ed tasks complete.

```fun
imp std.channel;

async fun produce(Channel<num>* out, num v) {
  out <- v * v;
}

fun main() num {
  Channel<num> ch = channel_new_cap(0, 8);
  fork produce(&ch, 2);
  fork produce(&ch, 3);
  ret (<-ch) + (<-ch); // 4 + 9 = 13 (arrival order)
}
```

## Control Flow
### If / Elif / Else
```fun
fun main() {
  num x = 1;
  if x > 0 {
    _ = x;
  } elif x == 0 {
    _ = x;
  } else {
    _ = x;
  }
}
```

### For
- Range: `for i : 0..10 { ... }`
- Array: `for item : arr { ... }`
- Indexed: `for i, item :: arr { ... }` (arrays and `Vec` only — the source must be indexable)
- Iterator: `for item : collection { ... }` — any value whose type implements the
  `Iterator` quirk, or exposes an `iter()` method returning one, can be iterated. The
  compiler desugars it to the iterator's `next()`/`Option` protocol, so `Vec`, `Set`,
  and `Map` (over its keys) all work: `for n : my_vec { ... }`, `for x : my_set { ... }`,
  `for key : my_map { ... }`. `break`/`continue` in the body target the loop as usual.
- Map pairs: `for k, v :: map { ... }` binds each key to `k` and its value to `v`.
- While-style (condition): `for i < len { ... }`
- Infinite loop: `for true { ... }`
- This style is used in stdlib (for example `std/string.fn`, `std/net.fn`, and `std/fs.fn`).

### Fit (Pattern Matching)
```fun
enum Color { Red, Green, Blue }

fun main() {
  Color c = .Red;
  fit c {
    .Red -> { _ = c; },
    .Green -> { _ = c; },
    _ -> { _ = c; }
  }
}
```
- Missing variants may produce warnings unless `_` is present.

### Data-carrying enums (tagged unions)
A variant may carry a positional payload, making the enum a tagged union (sum
type). Construct longhand `Enum.Variant(args)` or shorthand `.Variant(args)`
(when the expected enum type is known). Pattern matching destructures the payload
into locals.
```fun
compound Vec2 { num x; num y; }

enum Shape {
  Circle(num),          // primitive payload
  Rect(num, num),       // multiple payload fields
  At(Vec2),             // compound payload (by value)
  Empty,                // payload-free variant
}

fun area(Shape s) num {
  fit s {
    Shape.Circle(r) -> { ret r * r; }     // r binds the payload
    Shape.Rect(w, h) -> { ret w * h; }     // w, h bind the payload
    Shape.At(p) -> { ret p.x + p.y; }      // p is the compound payload
    Shape.Empty -> { ret 0; }
  }
  ret -1;
}

fun main() {
  Shape s = .Circle(5);   // shorthand construction
  _ = area(s);
}
```
- A tagged-union enum lowers to a C `struct { Enum_tag tag; union { ... } payload; }`.
- Payloads may be primitives, compounds (by value), or monomorphized generic
  instances (`Boxed(Box<num>)`).
- `fit` exhaustiveness (`fit_non_exhaustive`) covers data variants too; cover all
  variants or add `_`.

## Defer
- Expression: `defer close(fd);`
- Block: `defer { cleanup(); }`
- Runs in LIFO order when the current lexical scope exits.
- Function-scope defer runs before `ret` and before implicit function end.
- Loop-body defer runs at the end of each iteration.
- `continue` and `break` run defers from the current iteration before transferring control.

## Inline Assembly
```fun
fun main() {
  num x = 21 + 21;
  num y = 0;

  asm arch x86_64 volatile (out y: "=r" = y; in x: "r" = x; clobber "memory") {
    movq %[x], %[y]
  };

  asm arch aarch64 volatile (out y: "=r" = y; in x: "r" = x; clobber "memory") {
    mov %[y], %[x]
  };

  _ = y;
}
```
- `asm arch x86_64 { ... };` guards by target architecture.
- Use arch guards when the inline assembly differs by ISA (x86_64 vs aarch64).
- Operand names use the `%[name]` syntax inside templates.
- Outputs come first, then inputs, then clobbers (GCC-style extended asm).
- `volatile` prevents the compiler from removing or reordering the asm.
- Prefer the string form when you need precise escaping or newlines: `asm "...";`.
- Always list `"memory"` in clobbers when the asm reads/writes memory not mentioned in operands.

### Inline Assembly Pitfalls
- **ISA mismatch**: AArch64 register names (`x0`) will not assemble on x86_64. Guard by arch.
- **Operand order**: x86_64 uses `movq src, dst` (AT&T syntax) while AArch64 uses `mov dst, src`.
- **Missing size suffix**: x86_64 `mov` needs a size suffix (`movb/movw/movl/movq`).
- **Implicit clobbers**: If the asm touches memory not listed in operands, include `"memory"`.
- **Named receiver errors**: If you move values into locals via asm, ensure `out` targets are assigned to named locals.
- Block contents are preserved as raw text (including whitespace/comments).
- Fun does not validate asm syntax inside the block; final validity is determined by the selected C toolchain assembler/dialect.
- Example: `jmp $` can fail under clang/GAS inline asm, while local-label form (`1: ... jmp 1b`) is often accepted in that dialect.
- Pass computed values through operands, e.g. `num x = 21 + 21; num y = 0; asm volatile (out y: "=r" = y; in x: "r" = x) { mov %[x], %[y] };`.
- Use string form for explicit escaping: `asm "...";`.

## C Interop
- Import C headers via `imp std.c.*;`.
- C constants (e.g., `NULL`, `INT_MAX`) are allowed when headers are imported.
- `num` maps to `int64_t`; for `printf`, use `PRId64` (from `<inttypes.h>`) or cast to `long long` and use `%lld`.

## C Compiler Selection

By default, `fun` uses `zig cc`. You can override the compiler with environment variables:

- `FUN_CC`: compiler command. If it contains `{src}` and `{out}`, it is treated as a full template.
- `FUN_CC_ARGS`: extra arguments appended after the base command.

Examples:

- `FUN_CC=clang`
- `FUN_CC=zig` and `FUN_CC_ARGS="cc"`
- `FUN_CC="clang -O2 {src} -o {out}"`

`fun fuzz` does NOT use `FUN_CC`/`FUN_CC_ARGS` — it needs a compiler whose
toolchain bundles a coverage-guided fuzzing runtime specifically, which has
nothing to do with your ordinary build compiler, so it has its own separate
`FUN_FUZZ_CC` override instead (see Fuzzing below).

## Runtime Backend Selection

`std.runtime_backend` selects the runtime backend with this precedence:

1. `FUN_RUNTIME_BACKEND` (`posix`/`windows` or `1`/`2`)
2. `FUN_RUNTIME_OS` (`posix`/`unix`/`windows`)
3. Host hints from environment (`OS`, `OSTYPE`)
4. Fallback to `posix`

`std.thread_runtime` and `std.sync_runtime` follow the same selector.

## Deadlock Watchdog (opt-in)

Concurrent programs (`fork` and/or channels) can opt into a runtime deadlock
watchdog via environment variables. It is OFF by default: with the variable
unset the runtime is byte-identical — no watchdog thread, no timed waits, no
overhead.

- `FUN_DEADLOCK_WATCHDOG_MS=<ms>` — arm the watchdog with a stall threshold in
  milliseconds. When outstanding work exists but no scheduler progress happens
  and at least one task is parked in a blocking channel wait for the whole
  window, the runtime prints `fun: possible deadlock: <n> blocked, <n> pending, no progress for <ms>ms`
  to stderr and keeps running (warn-and-continue; semantics unchanged).
- `FUN_DEADLOCK_ABORT=1` — in addition, `abort()` the process on detection
  (nonzero exit + the diagnostic), for CI/fail-fast use.

The watchdog is a diagnostic aid; it never changes the behavior of a correct
program. Choose a threshold comfortably above your longest legitimate blocking
wait to avoid warning on slow-but-live operations.

## Testing
- `test "description" { ... }` at the top level; body reuses ordinary statement
  parsing (`assert`, `panic`, `if`/`for`, ... all work inside).
- Ignored entirely by an ordinary compile (not type-checked, not emitted) —
  matches `zig build` vs `zig test`.
- `fun test <path>` (or `-test`) compiles every discovered `test` block into a
  runner and runs it. Tests run CONCURRENTLY, one per virtual task (`fork`),
  printing `test: <name> ... PASS`/`FAIL` in completion order plus a final
  `N/N tests passed` summary.
- `fun test <path> -- "exact name"` filters to just the matching test(s) — no
  separate flag; this is what an editor's per-test Run/Debug button uses.
- A failing `assert` inside a test is caught and reported as `FAIL` without
  aborting the run — every other test still executes. `panic` still aborts
  the whole process (no per-test recovery for it); prefer `assert`.
- `imp std.mock_time;` gives a `Clock` quirk (`SystemClock`/`MockClock`) for
  testing time-dependent code deterministically, with no real waiting — see
  the Testing section of `docs/language.md` for a worked example.

## Fuzzing
- `fuzz "description" (data, len) { ... }` at the top level. `data`/`len` have
  no type annotation — always `raw*`/`num` (a byte buffer and its length),
  since that shape never varies.
- Ignored entirely by an ordinary compile or `fun test` run, same reasoning
  as `test` blocks.
- `fun fuzz <path> [<target>]` (or `-fuzz [-fuzz-target <name>]`) compiles the
  named `fuzz` block (or the only one, if there's just one) into a harness
  with no `main` of its own — a coverage-guided fuzzing engine's own driver
  supplies one, generating/mutating inputs toward ones that explore new code
  paths, and saving any input that crashes the harness for later repro.
- Unlike `test`, a crash (a failing `assert`, a real memory error) inside a
  `fuzz` block is the whole point — it's left to abort the process outright
  so the engine detects it.
- Everything after `--` passes straight through to the engine's own argv
  (ordinary Fun program-arg passthrough, no fuzz-specific wiring) — this is
  how you control the ENGINE (`-max_total_time=N`, `-runs=N`, `-max_len=N`,
  a corpus directory, ...), as opposed to `-fuzz-target`, which picks which
  Fun `fuzz` block gets built. See the engine's own `-help=1` for the full
  flag list.
- Needs a compiler whose toolchain bundles that coverage-guided runtime —
  not guaranteed on every platform/default install (notably: NOT Xcode's
  bundled clang on macOS). `fun fuzz` tries `clang` first, then falls back
  to Homebrew's LLVM (macOS) / versioned `clang-N` (Linux) / the official
  LLVM installer's default path (Windows) before failing with a clear
  message.
- `FUN_FUZZ_CC` points at a specific compiler if none of those work for you.
  Deliberately SEPARATE from `FUN_CC` (see C Compiler Selection above) —
  your normal build compiler has nothing to do with whether it can ALSO do
  coverage-guided fuzzing, so `fun fuzz` never reads `FUN_CC` at all; the
  two build paths can use different compilers safely.
- If it compiles but hangs on running: some sandboxed/containerized
  environments hang during AddressSanitizer's own startup, unrelated to Fun
  or the fuzzing engine. `FUN_FUZZ_NO_ASAN=1` drops just the memory-safety
  half of the sanitizer flag — fuzzing still runs and still finds crashes.
- Windows is unverified: the macOS (via the Homebrew-LLVM fallback) and
  (expected, by similar reasoning) Linux paths have actually been confirmed
  working; Windows has not, for lack of a machine to test on. Plain LLVM
  `clang.exe` (not `clang-cl.exe`) should in principle accept the same
  flags, but whether the runtime is bundled and the result runs correctly
  is genuinely unverified.

## Formatting
- `fun -fmt -in file.fn` formats a file in place.
- `fun -fmt-all -in file.fn` formats local imports (skips `std.*`).
- Asm block contents are preserved as raw text.

## Tooling (fls)
- Language Server for diagnostics and formatting.
- On save with format-on-save enabled, fls uses a single `fun -fmt-diag -no-exec` subprocess to format the file and collect diagnostics simultaneously, avoiding the cost of two sequential compiler invocations.
- When format-on-save is disabled, diagnostics use `fun -no-exec` under the hood.
- A 1500 ms debounce prevents redundant diagnostic subprocess launches when formatting already ran one on the same save event.

## VS Code Debug Experience
- **▶ Run** and **⚙ Debug** code lenses appear above every `fun main(` declaration.
- **▶ Run** compiles and runs the file in an integrated terminal.
- **⚙ Debug** performs a three-step build: `fun -g -no-exec -outf` → C compiler with `-g`/`/Zi` → native debugger launch.
- `-g` embeds `#line N "file.fn"` directives in the generated C so DWARF maps directly to Fun source lines.
- Breakpoints, call stack, and step-through work on `.fn` files without any manual configuration.
- Variable types are remapped from C (`int64_t`, `char*`, `bool`, …) to Fun (`num`, `str`, `bin`, …) via a DAP message tracker.
- Internal C boilerplate frames (`__fun_async_entry_*`, etc.) are marked secondary and collapsed in the call stack.
- Temp `.c` and compiled binary files are created in the OS temp directory and deleted automatically when the session ends.
- Debugger auto-detection order: `fun.debugger.type` setting → CodeLLDB → cpptools → platform default (CodeLLDB on macOS/Linux, cpptools on Windows).
- On Windows: tries `clang-cl` (DWARF, works with CodeLLDB) then `cl.exe` (CodeView, works with cpptools MSVC engine).

## Standard Library (high level)
- `std.array`: array helpers
- `std.io`: file helpers + print utilities, plus a `Sink` write destination (`Sink.Stdout`/`Stderr`/`Stdin`/`File(File)`) with `write`/`try_write`/`flush` and `write_to`/`writeln_to`, and a `RotatingSink` (size-capped, generation-rolling file logger). `stderr`/`stdin` are reachable via the `std.c.io` stream accessors (`stdout_stream`/`stderr_stream`/`stdin_stream`).
- `std.vec`: dynamic vectors
- `std.map`: generic maps (`Map<K, V>`) with typed keys/values and bytewise hashed lookups by default
- `std.set`: sets built on maps
- `std.option`: generic `Option<T>` container
- `std.result`: generic `Result<T, E>` container (`Ok(T)`/`Err(E)`); the free-function constructors (`ok`/`err`/`err_kind`/`err_error`) are fixed to `E = Error` — a custom `E` is constructed directly via `ret .Err(CustomKind.Variant);`
- `std.collections`: collection quirks (len/is_empty)
- `std.string`: string helpers
- `std.channel`: bounded blocking channels (ring buffer) with timeout send/recv, non-blocking `try_send`/`try_recv`, cancellation-aware send/recv helpers (`send_with_cancel`, `recv_into_with_cancel`, token variants `*_with_token`, timeout variants), default-branch select helpers (`select_recv_default_with`, `select_recv3_rr_default_with`), cancellation-aware select APIs (`*_with_cancel`, token variants `*_with_token`), dedicated cancel tokens (`ChannelCancelToken`, `channel_cancel_token_*`), status helper symbols (`channel_rc_*`), select index helpers (`channel_select_index_*`), and channel-level/per-call select wait-slice/backoff tuning (timeout and blocking variants), with synchronization routed through `std.sync_runtime`
- `std.thread`: POSIX-backed thread helpers (`thread_new`, method and helper forms for start/join/detach)
- `std.runtime_backend`: shared runtime backend selector helpers (`runtime_backend_*`) with environment overrides (`FUN_RUNTIME_BACKEND`, `FUN_RUNTIME_OS`)
- `std.thread_backend_posix`: POSIX thread backend module (`thread_backend_posix_*`) used by `std.thread_runtime`
- `std.thread_backend_windows`: Windows thread backend module (`thread_backend_windows_*`) with direct thread lifecycle operations over `std.c.thread_windows`
- `std.thread_runtime`: backend-facing thread runtime shim (`runtime_thread_*`) plus backend selector helpers (`thread_runtime_backend_*`), routed through `std.runtime_backend` and backend modules
- `std.thread_pool`: POSIX-backed thread pool helpers (`thread_pool_new`, start_all/join_all/detach_all) routed through `std.thread_runtime`
- `std.sync_backend_posix`: POSIX sync backend module (`sync_backend_posix_*`) used by `std.sync_runtime`
- `std.sync_backend_windows`: Windows sync backend module (`sync_backend_windows_*`) with direct mutex/condvar operations over `std.c.thread_windows`
- `std.sync_runtime`: backend-facing sync runtime shim (`runtime_mutex_*`, `runtime_condvar_*`) plus backend selector helpers (`sync_runtime_backend_*`), routed through `std.runtime_backend` and backend modules
- `std.sync`: POSIX-backed mutex/condition variable helpers (method and helper forms)
- `std.json`: typed JSON via the `JsonValue` data enum (`Null`/`Bool`/`Num`/`Str`/`Array`/`Object`); `parse(str) -> Result<JsonValue>`, Option-returning accessors (`as_num`/`as_str`/`as_bool`/`as_array`/`get(key)`/`index(i)`/`len`/`is_null`), and `to_string`/`stringify`. Structured (de)serialization of your own compounds via `std.quirks`' generic `To<JsonValue>`/`From<JsonValue>` (hand-implemented — Fun has no reflection), plus `to_json_value`/`to_json_string` convenience wrappers.
- `std.toml`: typed flat `key = value` TOML via the `TomlValue` enum (`Str`/`Int`/`Float`/`Bool`); `parse_document`, typed `get(key) -> Option<TomlValue>`, `as_int`/`as_float`/`as_str`/`as_bool`, and `stringify`.
- `std.serde`: text-layer `to_string`/`from_string`, dispatching through `std.quirks`' generic `To<str>`/`From<str>` (implemented by `JsonValue` and `TomlDoc`).
- `std.log`: structured logging. `LogLevel` (`Trace`/`Debug`/`Info`/`Warn`/`Error`/`Fatal`, explicit ordered values), `LogFormat` (`Text`/`Json`), and a `Logger` that filters by level and routes to any `std.io.Sink`. Bare methods (`info`/`warn`/`error`/...) emit immediately; the fluent by-value builder (`l.info_r("msg").str_field(k,v).num_field(k,n).emit()`) attaches typed key/value fields. Text renders `[LEVEL] <ts> [name] msg k=v`; JSON renders one object per line (deterministic field order). Fluent config: `logger_init`/`logger_json`, `as_format`/`to_sink`/`named`/`route_errors`/`with_timestamps`. `route_errors(true)` sends `Warn`+ to stderr.
- `std.quirks`: common quirks — `Sized`, `Display`, `Clearable`, `Iterator<T>`, and the generic conversion quirks `To<T>`/`From<T>` (e.g. `impl Config as To<JsonValue>`), which back `std.json`'s structured (de)serialization and `std.serde`'s text-layer `to_string`/`from_string` alike.
- `std.time`, `std.rand`, `std.math`, `std.path`, `std.net`, etc.
- `std.mock_time`: a `Clock` quirk for time-mocked tests — `SystemClock` (the real clock) and `MockClock` (a fully controllable fake one, advanced only via explicit `advance`/`set` calls, never real time)
- `std.testing`: the concurrent test-mode runner (`run_discovered_tests`) `fun test` auto-imports and calls into — not intended to be used directly from ordinary Fun source
- `std.sys`: environment and process helpers (`sys_exit`, `sys_abort`, `sys_system`)
- `std.net`: URL parsing + pure Fun POSIX TCP/HTTP helpers (POSIX sockets)

## CLI
```
fun -in <input_file> [-out <output_file>] [-no-exec] [-outf] [-ast] [-test] [-fuzz] [-fuzz-target <name>] [-help]
fun test <input_file>   (shorthand for `fun -in <input_file> -test`)
fun fuzz <input_file> [<target>]   (shorthand for `fun -in <input_file> -fuzz [-fuzz-target <target>]`)
fun build                (reads ./fun.toml, installs binaries under fun-out/bin/)
```

## Errors and Warnings
- Type mismatches, unknown symbols, and incomplete quirk implementations are errors.
- Pointer-return, fit exhaustiveness, redundant fit branches, unreachable statements, constant assertions, and optional unused-* diagnostics are emitted as warnings.

### Warning IDs
- `return_local_ptr`
- `fit_non_exhaustive`
- `fit_unreachable_branch`
- `unreachable_code`
- `assert_constant`
- `unused_variable` (with `-warn-unused`)
- `unused_import` (with `-warn-unused`)
- `unused_function` (with `-warn-unused`)
- `unused_compound` (with `-warn-unused`)
- `missing_return` (non-`void` function may reach its end without returning; always checked)
- `blocking_fork_deadlock` (with `-warn-unused`) — `wait_group_new(0)` + `fork` in a loop that `done()`s the group; size the WaitGroup to the task count
- `shared_mutable_capture_race` (with `-warn-unused`) — a non-`Mutex`/`Channel` compound shared by `&` into a mutating `async fun` forked multiple times; guard or copy per task
- `integer_literal_out_of_range` (with `-warn-unused`) — a compile-time integer literal does not fit the declared `uN`/`iN` width, or a negative value is assigned to an unsigned `uN`
- `channel_capacity_overflow` (with `-warn-unused`) — more statically-known blocking sends than a bounded channel's literal capacity, with no concurrent receiver, so the producer blocks (e.g. `channel_new_cap(0, 1)` then three `<-` sends)

### Warning Control Statements
- `allow <warning_id>, "reason";`
- `expect <warning_id>, "reason";`

Rules:
- Valid inside function bodies. At module scope, only `unused_variable`, `unused_import`, `unused_function`, and `unused_compound` may be controlled, and they apply to the next top-level declaration or import in file order.
- `reason` must be a string literal.
- `allow` suppresses the next warning emitted with the given ID.
- `expect` suppresses the next warning emitted with the given ID and fails compilation if that warning is never emitted.

Example:
```fun
fun main() {
  bin x = true;
  allow fit_non_exhaustive, "temporary while migrating branches";
  fit x {
    true -> { }
  }
}
```

Expect example:
```fun
fun main() {
  bin x = true;
  expect fit_non_exhaustive, "guard intentional partial fit during migration";
  fit x {
    true -> { }
  }
}
```

Additional examples:
- examples/advanced/warning_allow.fn
- examples/advanced/warning_expect.fn
- examples/advanced/return_local_ptr_allow.fn
- examples/advanced/unused_variable_warning.fn
- examples/advanced/unused_variable_allow.fn
- examples/advanced/unused_variable_expect.fn
- examples/advanced/unused_import_warning.fn
- examples/advanced/unused_import_allow.fn
- examples/advanced/unused_import_expect.fn
- examples/advanced/unused_function_warning.fn
- examples/advanced/unused_function_allow.fn
- examples/advanced/unused_function_expect.fn
- examples/advanced/unused_compound_warning.fn
- examples/advanced/unused_compound_allow.fn
- examples/advanced/unused_compound_expect.fn
- examples/advanced/fit_unreachable_branch_warning.fn
- examples/advanced/unreachable_code_warning.fn
- examples/advanced/assert_constant_warning.fn
- examples/error_cases/warning_expect_unmet.fn (expected compile failure)
