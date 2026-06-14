
# Fun Language Reference

## Language Features

### Syntax & Structure
- **Statically-typed, C-inspired**: Variables and functions are statically typed; variables can be explicitly typed or inferred via `let`.
- **Functions**: Defined with `fun name(args) type { ... }`.
- **Imports**: Use `imp module;` to import standard or user modules. Use `imp module as alias;` to import with a namespace alias.
- **Visibility**: Prefix declarations with `pub` to export them; declarations without `pub` are module-private.
- **Compounds**: Custom types (like structs): `compound Point { num x; num y; }`.
- **Quirks (Interfaces)**: Define required methods: `quirk Shape { area() num; }`.
- **Implementations**:
    - Quirk implementation: `impl Rectangle as Shape { ... }`
    - Plain compound methods: `impl Point { ... }`
- **Pattern Matching**: `fit x { ... }` for value-based branching.
- **Async/Await**: Async functions are declared with `async fun ...`; async calls must be awaited with `await` inside async functions.
- **Comments**: Use `//` for single-line comments.

### Types
- **Primitive Types**:
    - `num`: Signed 64-bit integer (maps to C `int64_t`)
    - `dec`: 64-bit floating-point (IEEE double; maps to C `double`)
    - `f32`: 32-bit floating-point (maps to C `float`)
    - `f64`: 64-bit floating-point (maps to C `double`)
    - `i8`, `i16`, `i32`, `i64`: Signed fixed-width integers
    - `u8`, `u16`, `u32`, `u64`: Unsigned fixed-width integers
    - `iN`, `uN`: Arbitrary-width signed/unsigned integers
    - `str`: String
    - `bin`: Boolean
    - `chr`: Character
    - `raw`: Opaque/"void" type (use `raw*` for C-style `void*`)
- **Arrays**: `num[] arr = [1, 2, 3];`
- **Pointers**: `Node* next;` (self-referential and forward-declared types supported)
- **`nil`**: The null pointer/string sentinel (a keyword; lowers to C `NULL`). It
  coerces to any pointer type and to `str`, and compares with `==` / `!=`:
  `num* p = nil;`, `if p == nil { ... }`, `Node{next = nil}`. No import needed
  (unlike the C macro `NULL`, which requires `imp std.c.def;`).
- **Type Inference**: Supported for variables via `let name = expr;` (initializer required).

#### Type Inference (let)
- `let` always requires an initializer; the compiler infers the declared type from the expression.
- Inference follows common literals and expressions:
    - Numeric literals infer `num` or `dec` depending on literal form.
    - `"text"` infers `str`, `'c'` infers `chr`, `true/false` infers `bin`.
    - Array literals infer `T[]` from elements (for example `[1, 2]` -> `num[]`).
    - Function calls infer the function's return type.
    - Member access uses the receiver type (for example `Point p; let x = p.x;` -> `num`).
    - Indexing an array uses the element type (for example `let v = nums[i];` -> `num`).
- If the expression mixes numeric types, inference prefers the wider category (`dec` over `num`).

### Enums
- **Declaration**: `enum Color { Red, Green, Blue }`
- **Longhand access**: `Color.Red` (works even if the enum is declared later in the file).
- **Shorthand access**: `.Red` (contextual; the expected enum type must be known from assignment, argument, or `fit`).
- **Assignments**:
    - `Color c = Color.Green;`
    - `Color c = .Green;`
- **Function arguments**:
    - `fun takes(Color c) { ... }`
    - `takes(.Blue);`
- **Pattern matching (`fit`)**:
    - `fit c { .Red -> { ... }, .Green -> { ... }, _ -> { ... } }`
    - `fit c { Color.Red -> { ... }, Color.Green -> { ... }, Color.Blue -> { ... } }`
- **Exhaustiveness**: Missing enum variants in `fit` may emit `fit_non_exhaustive`; redundant branches or catch-alls may emit `fit_unreachable_branch`.

#### Data-carrying enums (sum types / tagged unions)
A variant may carry a positional payload, turning the enum into a tagged union (a
payload-carrying sum type). An enum becomes a tagged union as soon as *any* variant has a
payload; payload-free variants still coexist.

- **Declaration**: `enum Shape { Circle(num), Rect(num, num), Empty }`
    - A payload is a parenthesized, comma-separated list of types: `Circle(num)`,
      `Rect(num, num)`. Payloads can be primitives, compounds (by value), or
      monomorphized generic instances (`Boxed(Box<num>)`).
- **Construction**:
    - Longhand: `Shape s = Shape.Circle(5);`  `Shape r = Shape.Rect(3, 4);`
    - Shorthand (expected type known): `Shape s = .Circle(5);`  `ret .Some(x);`
    - A payload-free variant is constructed like a normal enum value: `Shape e = Shape.Empty;`
- **Pattern matching with destructuring**: each arm binds the matched variant's
  payload into locals visible in the arm body.
    ```fun
    fit s {
        Shape.Circle(r) -> { ret r * r; }       // r is the payload
        Shape.Rect(w, h) -> { ret w * h; }       // w, h are the payload
        Shape.Empty -> { ret 0; }
    }
    ```
    - The shorthand arm form (`.Circle(r) -> ...`) works too, and a `_ -> { ... }`
      catch-all covers the remaining variants.
- **Lowering**: a tagged-union enum emits a C `struct { Enum_tag tag; union { ... } payload; }`;
  payload-free (plain) enums keep the classic C `enum` lowering for full backward compatibility.
- **Exhaustiveness**: the same `fit_non_exhaustive` check applies — cover every
  variant or add a `_` catch-all.

### Control Flow
- **If/Else**: Standard conditional branching.
- **Elif**: Else-if chaining.
- **Pattern Matching**: `fit` statement for exhaustive and non-exhaustive matches.
- **Assert**: `assert <condition>;` aborts if condition is false. Optional message: `assert <condition>, "msg";`. Constant assertions may emit `assert_constant`.
- **Unreachable Statements**: Statements after `ret`, `break`, or `continue` may emit `unreachable_code`.
- **For Loops**:
    - Range: `for i : 0..10 { ... }`
    - Array: `for item : arr { ... }`
    - Indexed: `for i, item :: arr { ... }` (indexable sources only — arrays and `Vec`)
    - Iterator: `for item : collection { ... }` — drives any value whose type implements the `Iterator` quirk (`next() Option<T>`) or exposes an `iter()` returning one. Desugars to the `next()`/`Option` protocol, so `Vec`, `Set`, and `Map` (keys) iterate directly.
    - Map pairs: `for k, v :: map { ... }` binds each key to `k` and its value to `v`.
    - While-style (condition): `for i < len { ... }`
    - Infinite loop: `for true { ... }`
    - Common in stdlib (for example `std/string.fn`, `std/net.fn`, and `std/fs.fn`).

### Defer
- **Purpose**: Run cleanup logic automatically when the current lexical scope exits.
- **Order**: LIFO (last `defer` runs first).
- **Forms**:
    - Expression: `defer close(fd);`
    - Block: `defer { log("done"); cleanup(); }`
- **Scope semantics**:
    - A `defer` runs when the scope where it appears exits.
    - Function-scope defers run before `ret` and before implicit function end.
    - Loop-body defers run at the end of each iteration.
    - On `continue`/`break`, defers in the current loop iteration run before control leaves that iteration.

### Inline Assembly
- **Block form**: `asm { ... };`
- **String form**: `asm "...";` (use this for exact formatting/escapes)
- **Volatile**: `asm volatile { ... };` prevents reordering/elision
- **Architecture guard**: `asm arch x86_64 { ... };` (errors if target arch mismatches)
- **Operands & clobbers**:
    - Syntax:
      - `asm volatile (out dst: "=r" = result; in src: "r" = value; clobber "rax", "memory") { ... };`
    - Reference named operands in templates using `%[name]`.
    - Outputs are first, then inputs, then clobbers (GCC-style extended asm).
        - Example (pass computed value):
            - `num x = 21 + 21;`
            - `num y = 0;`
            - `asm volatile (out y: "=r" = y; in x: "r" = x) { mov %[x], %[y] };`
- **Notes**:
    - Asm block contents are preserved as raw text (including spaces, tabs, newlines, and comments).
    - Fun does not validate assembly syntax inside asm blocks; correctness is decided by the downstream assembler/dialect (for example clang/GAS vs NASM differences).
    - Use the string form when you need explicit escape control.
    - Example (x86-style): `jmp $` may fail under clang/GAS inline asm; label form like `1: ... jmp 1b` is typically more portable in that pipeline.
    - Supported arch names: `x86_64`/`amd64`, `x86`/`i386`, `aarch64`/`arm64`, `arm`.

### Functions
- **Definition**: `fun name(type arg, ...) return_type { ... }`
- **Return**: Use `ret value;` to return from a function.
- **No Nested Functions**: Functions cannot be declared inside other functions.
- **Generic Functions**: `fun id<T>(T x) T { ret x; }`
    - Type arguments are inferred from call sites: `num v = id(1);`.
- **Default parameter values**: A parameter may declare a default with `= expr`; a
  call that omits it uses the default.
    ```fun
    fun greet(str name, num times = 1, str sep = ", ") {
      // implementation
    }
    greet("a");           // times = 1, sep = ", "
    greet("a", 3);        // times = 3, sep = ", "
    greet("a", 3, "; ");  // all explicit
    ```
    - **Trailing only**: defaulted parameters must come last — a required parameter
      cannot follow a defaulted one.
    - **Self-contained defaults**: a default expression is evaluated at the *call site*,
      so it may not reference `self` or an earlier parameter (use a constant, a global,
      `nil`, an enum variant, or another self-contained expression). Pointer defaults
      like `num* p = nil` are allowed.
    - Works for free functions and methods (including generic, `async`, and
      pointer-receiver methods).

### Async / Await
- **Async function declaration**: `async fun name(args) type { ... }`
- **Await usage**: `await` is valid only inside an `async fun` body.
- **Required await**: Calls to async functions and async quirk methods must be awaited.
- **Await target**: The awaited expression must resolve to an async call.

Example:
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

### Concurrency: virtual threads (`fork`) & channels
- **`fork <call>;`** spawns a *virtual thread* — a fire-and-forget task that runs
  on a runtime **M:N scheduler**: a small pool of OS worker threads (sized to the
  CPU count) multiplexes many cheap `fork` tasks. The target is an `async fun`.
  `fork` returns nothing; results flow back through channels.
- **Automatic drain**: `main` blocks until every `fork`ed task has completed before
  it returns, so spawned work always finishes.
- **Cooperative**: a task that blocks on a channel op holds its worker (the yield
  points are the blocking primitives). It is not preemptive.
- **Channel operators** (sugar over `std.channel`):
  - `ch <- v` — send `v` into `ch` (equivalent to `ch.send(v)`).
  - `<-ch` — receive from `ch` (equivalent to `ch.recv()`, lossy; use
    `ch.recv_into(&out)` for the error-aware form).
  - Note: `a < -b` (a comparison against a negative) is unaffected — only the glued
    `<-` (no space) is the channel operator.
- **Result-style send/recv** (`std.channel`): the low-level `recv_into`/`send` return a
  numeric status code, but the ergonomic layer returns a value you can `fit` on:
  - `ch.recv_result()` → `RecvResult<T>` with variants `Ok(T)`, `Closed`, `Timeout`,
    `Cancelled`, `Error(num)` (also `recv_result_timeout`, `recv_result_with_token`,
    `try_recv_result`, and `*_async` variants).
  - `ch.send_result(v)` → `SendResult` with variants `Ok`, `Closed`, `Full`,
    `Cancelled`, `Error(num)` (also `send_result_timeout`, `try_send_result`, async).
    ```fun
    fit ch.recv_result() {
      RecvResult.Ok(v) -> {
        // use v
        _ = v;
      }
      RecvResult.Closed -> {
        // drained
      }
      RecvResult.Timeout -> {
        // retry
      }
      RecvResult.Cancelled -> { }
      RecvResult.Error(e) -> {
        _ = e;
      }
    }
    ```
- **`std.task` WaitGroup**: wait for a batch of `fork`ed tasks. `wait_group_new(n)`,
  each task calls `wg.done()`, and `wg.wait()` blocks until all `n` complete.

Example:
```fun
imp std.channel;

async fun square_into(Channel<num>* out, num v) {
    out <- v * v;
}

fun main() num {
    Channel<num> results = channel_new_cap(0, 8);
    fork square_into(&results, 2);
    fork square_into(&results, 3);
    num total = (<-results) + (<-results);
    ret total; // 4 + 9 = 13
}
```

### Compounds & Quirks
- **Compounds**: Like C structs, can have methods via `impl`.
- **Private fields (leading `_`)**: A compound field whose name begins with an
  underscore is module-private — readable/writable only from code in the same
  module as the compound's declaration (including its own `impl` methods via
  `self._field`). No keyword is needed; the leading `_` is the marker. Another
  module must go through public accessor methods. Example:
    ```fun
    compound Account {
        num id;          // public
        num _balance;    // private to this module
    }
    impl Account {
        pub balance() num { ret self._balance; }   // self._balance is fine here
    }
    // In another module: `acc._balance` is rejected; `acc.balance()` works.
    ```
- **Quirks**: Like interfaces/traits, define required methods.
- **Impl**: Attach methods to compounds or implement quirks for compounds.
- **Method Dispatch**: Quirk values can be used for dynamic dispatch (like trait objects).
- **Quirk Method Visibility**: Quirk methods follow normal visibility rules. Non-`pub` methods are callable inside the declaring module, but are not callable from importing modules.
- **Display Formatting (`{}`)**: Formatting uses `Display.to_string()` only when that method is accessible at the call site. If `to_string()` is private in another module, formatting falls back to pointer-style output for that value.

### Imports & Modularity
- **Standard Library**: `imp std.c.io;` maps to C standard headers.
- **Relative Imports**: `imp relative.parent;` for user modules.
- **Import Alias**: `imp mod1 as one;` then call symbols as `one.some_fn()`.
- **Duplicate Export Collisions**: Import modules that export the same public symbol by aliasing each module and calling through the alias namespace.
    - Example:
        - `imp mod1 as one;`
        - `imp mod2 as two;`
        - `num a = one.pick();`
        - `num b = two.pick();`
- **Circular Dependency Detection**: Compiler detects and errors on circular imports.

### C Interop
- **C Macros**: ALL_CAPS identifiers (e.g., `NULL`, `INT_MAX`) are allowed if the right header is imported.
- **Direct Mapping**: `imp std.c.*;` maps to C headers (`stdio.h`, `limits.h`, etc.).
- **Signature-only stdlib**: Fun stdlib modules only declare signatures; C provides implementations.
- **Printf formats**: `num` is `int64_t` in C. Use `PRId64` (from `<inttypes.h>`) or cast to `long long` with `%lld` when printing.
- **Compiler selection**: `fun` uses `zig cc` by default. Override with `FUN_CC` and optional `FUN_CC_ARGS`.

### Standard Library Highlights
- **std.io**: file helpers + `print`/`println`/`print_num`/`print_dec`/`print_bin`
- **std.sys**: env access, process control (`sys_exit`, `sys_abort`, `sys_system`), and PRNG wrappers
- **std.net**: URL parsing, HTTP GET builder, and a best-effort local HTTP server launcher
    - Note: std.net TCP/HTTP helpers use POSIX sockets via `std.c.net`.
- **std.option**: Generic `Option<T>` container with `some<T>`/`none<T>` helpers.
- **std.result**: Generic `Result<T>` container with `ok<T>`/`err<T>` helpers.
- **std.collections**: Collection quirk helpers (len/is_empty).

### Error Handling
- **Type Checking**: Errors for type mismatches, e.g., assigning `str` to `num`.
- **Undeclared Symbols**: Errors for using undeclared variables or functions.
- **Duplicate Declarations**: Errors for redeclaring variables in the same scope.
- **Missing Imports**: Errors for importing non-existent modules.
- **Incomplete Quirk Implementations**: Errors if not all quirk methods are implemented.

### Warning Controls
- **Stable warning IDs**:
        - `return_local_ptr`
        - `fit_non_exhaustive`
    - `fit_unreachable_branch`
    - `unreachable_code`
    - `assert_constant`
    - `unused_variable` (with `-warn-unused`)
    - `unused_import` (with `-warn-unused`)
    - `unused_function` (with `-warn-unused`)
    - `unused_compound` (with `-warn-unused`)
    - `missing_return` — a non-`void` function/method that can reach the end of its
      body without returning a value (the emitted C would return an indeterminate
      value). The analysis is conservative: a trailing `ret`, an exhaustive
      `if/elif/else` where every branch returns, a `fit` with a default branch whose
      arms all return, and infinite loops (`for {}` / `for true {}` with no `break`)
      all count as returning. Always checked (not gated behind `-warn-unused`).
- **Suppress next warning intentionally**:
        - `allow <warning_id>, "reason";`
- **Require next warning to appear**:
        - `expect <warning_id>, "reason";`
- **Scope**: `allow`/`expect` are statement directives. They work inside function bodies, and `unused_variable`, `unused_import`, `unused_function`, and `unused_compound` may also be controlled at module scope for the next top-level declaration or import.
- **Reason is required**: the intent string documents why the warning is being allowed/expected.
- **Behavior**:
        - `allow` consumes and suppresses the next emitted warning with that ID.
        - `expect` also suppresses the next warning with that ID, but compilation fails if no such warning is emitted later.

Example:
```fun
fun bad() num* {
    expect return_local_ptr, "tracked until allocator refactor";
    num x = 1;
    ret &x;
}

fun partial(bin x) {
    allow fit_non_exhaustive, "legacy branch set, cleanup pending";
    fit x {
        true -> { }
    }
}

fun main() {
    partial(true);
    num* p = bad();
    _ = p;
}
```

See also:
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
- examples/error_cases/warning_expect_unmet.fn

### Example
```fun
imp std.c.io;

compound Point { num x; num y; }

impl Point {
    translate(num dx, num dy) {
        self.x += dx;
        self.y += dy;
    }
}

fun main() {
    Point p;
    p.x = 1; p.y = 2;
    p.translate(3, 4);
    printf("p=(%d,%d)\n", p.x, p.y);
}
```

### Additional Features
- **Forward Declarations**: Compounds can reference each other regardless of order.
- **Self-referential Types**: Supported via pointers.
- **Pattern Matching**: Exhaustive and non-exhaustive with `_` default branch.
- **CLI Tool**: Compile, transpile, and run Fun code from the command line.

---

See the [examples directory](../examples/) for real code and advanced usage.
