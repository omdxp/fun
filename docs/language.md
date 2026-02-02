
# Fun Language Reference

## Language Features

### Syntax & Structure
- **Statically-typed, C-inspired**: All variables and functions have explicit types.
- **Functions**: Defined with `fun name(args) type { ... }`.
- **Imports**: Use `imp module;` to import standard or user modules.
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
    - `num`: Integer number
    - `dec`: Decimal (floating-point) number
    - `str`: String
    - `bin`: Boolean
    - `chr`: Character
    - `raw`: Opaque/"void" type (use `raw*` for C-style `void*`)
- **Arrays**: `num[] arr = [1, 2, 3];`
- **Pointers**: `Node* next;` (self-referential and forward-declared types supported)
- **Type Inference**: Not supported; all types must be explicit.

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
    - The block form is tokenized and re-spaced; use the string form if you need exact spacing or numeric formatting.
    - Supported arch names: `x86_64`/`amd64`, `x86`/`i386`, `aarch64`/`arm64`, `arm`.

### Functions
- **Definition**: `fun name(type arg, ...) return_type { ... }`
- **Return**: Use `ret value;` to return from a function.
- **No Nested Functions**: Functions cannot be declared inside other functions.

### Compounds & Quirks
- **Compounds**: Like C structs, can have methods via `impl`.
- **Quirks**: Like interfaces/traits, define required methods.
- **Impl**: Attach methods to compounds or implement quirks for compounds.
- **Method Dispatch**: Quirk values can be used for dynamic dispatch (like trait objects).

### Imports & Modularity
- **Standard Library**: `imp std.c.io;` maps to C standard headers.
- **Relative Imports**: `imp relative.parent;` for user modules.
- **Circular Dependency Detection**: Compiler detects and errors on circular imports.

### C Interop
- **C Macros**: ALL_CAPS identifiers (e.g., `NULL`, `INT_MAX`) are allowed if the right header is imported.
- **Direct Mapping**: `imp std.c.*;` maps to C headers (`stdio.h`, `limits.h`, etc.).
- **Signature-only stdlib**: Fun stdlib modules only declare signatures; C provides implementations.

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
