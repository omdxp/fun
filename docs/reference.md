# Fun Language Reference (Comprehensive)

## Overview
Fun is a statically-typed, C-transpiling language focused on performance and clarity. The compiler emits readable C and relies on the system C toolchain for linking and execution.

## Numeric Model (64-bit by default)
- `num` is a signed 64-bit integer (C `int64_t`).
- `dec` is a 64-bit floating-point number (C `double`).
- `bin` is boolean (`bool`).
- `chr` is a character (`char`).
- `str` is a null-terminated string (`char*`).
- `raw` is an opaque/void type (`void` in C; use `raw*` for `void*`).

## Source Structure
- **File extension**: `.fn`
- **Statements** end with `;`.
- **Blocks** are delimited with `{}`.
- **Comments**: `//` single-line.

## Imports
- `imp std.c.io;` imports a C header signature module.
- `imp std.string;` imports Fun stdlib modules.
- Relative imports are supported (e.g., `imp ..foo.bar;`).

## Types
### Built-in Types
- `num`, `dec`, `bin`, `chr`, `str`, `raw`

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
```

### Quirks (Interfaces)
```fun
quirk Shape {
  area() num;
}
```

### Implementations
```fun
impl Point {
  translate(num dx, num dy) {
    self.x += dx;
    self.y += dy;
  }
}

impl Rectangle Shape {
  area() num { ret self.w * self.h; }
}
```

### Generics
- Compounds and impls can be generic: `compound Vec<T> { ... }`.
- Use `Vec<num>` etc. where required.

## Variables
- All variables require a type declaration.
```fun
num x = 1;
str name = "fun";
```

## Functions
```fun
fun add(num a, num b) num {
  ret a + b;
}
```
- No nested function declarations.
- Use `ret` for return.

## Control Flow
### If / Elif / Else
```fun
if x > 0 {
  ...
} elif x == 0 {
  ...
} else {
  ...
}
```

### For
- Range: `for i : 0..10 { ... }`
- Array: `for item : arr { ... }`
- Indexed: `for i, item :: arr { ... }`

### Fit (Pattern Matching)
```fun
fit c {
  .Red -> { ... },
  .Green -> { ... },
  _ -> { ... }
}
```
- Missing variants may produce warnings unless `_` is present.

## Defer
- Expression: `defer close(fd);`
- Block: `defer { cleanup(); }`
- Runs in LIFO order before function exit.

## Inline Assembly
```fun
asm volatile (out y: "=r" = y; in x: "r" = x; clobber "memory") {
  mov x0, x0
};
```
- `asm arch x86_64 { ... };` guards by target architecture.
- Block contents are preserved by the formatter.
- Use string form for explicit escaping: `asm "...";`.

## C Interop
- Import C headers via `imp std.c.*;`.
- C constants (e.g., `NULL`, `INT_MAX`) are allowed when headers are imported.
- `num` maps to `int64_t`; for `printf`, use `PRId64` (from `<inttypes.h>`) or cast to `long long` and use `%lld`.

## Formatting
- `fun -fmt -in file.fn` formats a file in place.
- `fun -fmt-all -in file.fn` formats local imports (skips `std.*`).
- Asm block contents are preserved as raw text.

## Tooling (fls)
- Language Server for diagnostics and formatting.
- Diagnostics use `fun -no-exec` under the hood.

## Standard Library (high level)
- `std.array`: array helpers
- `std.vec`: dynamic vectors
- `std.map`: string-keyed maps
- `std.set`: sets built on maps
- `std.string`: string helpers
- `std.json`, `std.toml`: minimal serialization helpers
- `std.time`, `std.rand`, `std.math`, `std.path`, `std.net`, etc.

## CLI
```
fun -in <input_file> [-out <output_file>] [-no-exec] [-outf] [-ast] [-help]
```

## Errors and Warnings
- Type mismatches, unknown symbols, and incomplete quirk implementations are errors.
- Fit exhaustiveness and pointer-return warnings are emitted as warnings.
