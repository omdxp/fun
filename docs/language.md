
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
    - Quirk implementation: `impl Rectangle Shape { ... }`
    - Plain compound methods: `impl Point { ... }`
- **Pattern Matching**: `fit x { ... }` for value-based branching.
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
- **Type Inference**: Supported for variables via `let name = expr;` (initializer required).

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
- **Exhaustiveness**: Missing enum variants in `fit` may emit a warning unless a `_` catch-all branch is present.

### Control Flow
- **If/Else**: Standard conditional branching.
- **Elif**: Else-if chaining.
- **Pattern Matching**: `fit` statement for exhaustive and non-exhaustive matches.
- **Assert**: `assert <condition>;` aborts if condition is false. Optional message: `assert <condition>, "msg";`.
- **For Loops**:
    - Range: `for i : 0..10 { ... }`
    - Array: `for item : arr { ... }`
    - Indexed: `for i, item :: arr { ... }`

### Defer
- **Purpose**: Run cleanup logic automatically before a function returns.
- **Order**: LIFO (last `defer` runs first).
- **Forms**:
    - Expression: `defer close(fd);`
    - Block: `defer { log("done"); cleanup(); }`
- **Scope**: Defers execute before any `ret`, and before a function ends without an explicit `ret`.

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
- **Notes**:
    - The formatter preserves asm block contents as raw text; use the string form when you need explicit escape control.
    - Supported arch names: `x86_64`/`amd64`, `x86`/`i386`, `aarch64`/`arm64`, `arm`.

### Functions
- **Definition**: `fun name(type arg, ...) return_type { ... }`
- **Return**: Use `ret value;` to return from a function.
- **No Nested Functions**: Functions cannot be declared inside other functions.
- **Generic Functions**: `fun id<T>(T x) T { ret x; }`
    - Type arguments are inferred from call sites: `num v = id(1);`.

### Compounds & Quirks
- **Compounds**: Like C structs, can have methods via `impl`.
- **Quirks**: Like interfaces/traits, define required methods.
- **Impl**: Attach methods to compounds or implement quirks for compounds.
- **Method Dispatch**: Quirk values can be used for dynamic dispatch (like trait objects).

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
