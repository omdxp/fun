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
- Compounds and impls can be generic: `compound Vec<T> { ... }`.
- Use `Vec<num>` etc. where required.
- Impl type parameters can be constrained with `:` and `|`.
  - Example: `impl Vec<T: num | dec> { ... }`.
  - This lets one impl body work for a fixed set of concrete numeric types.

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
```

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
- Indexed: `for i, item :: arr { ... }`
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

## Runtime Backend Selection

`std.runtime_backend` selects the runtime backend with this precedence:

1. `FUN_RUNTIME_BACKEND` (`posix`/`windows` or `1`/`2`)
2. `FUN_RUNTIME_OS` (`posix`/`unix`/`windows`)
3. Host hints from environment (`OS`, `OSTYPE`)
4. Fallback to `posix`

`std.thread_runtime` and `std.sync_runtime` follow the same selector.

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
- `std.io`: file helpers + print utilities
- `std.vec`: dynamic vectors
- `std.map`: generic maps (`Map<K, V>`) with typed keys/values and bytewise hashed lookups by default
- `std.set`: sets built on maps
- `std.option`: generic `Option<T>` container
- `std.result`: generic `Result<T>` container
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
- `std.json`, `std.toml`: minimal serialization helpers
- `std.time`, `std.rand`, `std.math`, `std.path`, `std.net`, etc.
- `std.sys`: environment and process helpers (`sys_exit`, `sys_abort`, `sys_system`)
- `std.net`: URL parsing + pure Fun POSIX TCP/HTTP helpers (POSIX sockets)

## CLI
```
fun -in <input_file> [-out <output_file>] [-no-exec] [-outf] [-ast] [-help]
```

## Errors and Warnings
- Type mismatches, unknown symbols, and incomplete quirk implementations are errors.
- Fit exhaustiveness and pointer-return warnings are emitted as warnings.

### Warning IDs
- `return_local_ptr`
- `fit_non_exhaustive`

### Warning Control Statements
- `allow <warning_id>, "reason";`
- `expect <warning_id>, "reason";`

Rules:
- Valid only inside function bodies.
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
- examples/error_cases/warning_expect_unmet.fn (expected compile failure)
