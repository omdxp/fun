# Language

## Source Structure

- **File extension**: `.fn`.
- **Statements** end with `;`.
- **Blocks** are delimited with `{}`.
- **Comments**: `//` single-line, `/* ... */` block.
- **Visibility**: prefix a declaration with `pub` to export it; without
  `pub` it is module-private.

### Documentation comments

A regular `//` comment immediately above a declaration becomes its
documentation, picked up by the website reference and by hover in the
language server. This applies to module summaries, public symbols,
compound fields, and quirk members. Keep them short and
declaration-specific.

```fun
imp std.io;

// Optional value container. Named Maybe here (not Option) only to avoid
// colliding with std.option's own Option<T> for this standalone example.
pub compound Maybe<T> {
  // True when a value is present.
  bin has;
  // Stored value.
  T value;
}

// Value that can render itself as text. Named Renderable here (not
// Display) only to avoid colliding with std.quirks' own Display.
pub quirk Renderable {
  // Produce a textual representation.
  to_string() str;
}

fun main() {
  Maybe<num> opt;
  opt.has = true;
  opt.value = 42;
  println_fmt("has={bin} value={num}", opt.has, opt.value);
}
```

## Types

| Fun type | C representation | Notes |
|---|---|---|
| `num` | `int64_t` | Signed 64-bit integer, the default integer type. |
| `dec` | `double` | 64-bit floating-point. |
| `i8` / `u8` | `int8_t` / `uint8_t` | Fixed-width 8-bit integer. |
| `i16` / `u16` | `int16_t` / `uint16_t` | Fixed-width 16-bit integer. |
| `i32` / `u32` | `int32_t` / `uint32_t` | Fixed-width 32-bit integer. |
| `i64` / `u64` | `int64_t` / `uint64_t` | Fixed-width 64-bit integer. |
| `f32` | `float` | Fixed-width 32-bit float. |
| `f64` | `double` | Fixed-width 64-bit float. |
| `iN` / `uN` (arbitrary width) | Nearest standard container up to 128 bits, `_BitInt(N)`/`unsigned _BitInt(N)` past that | See Platforms & Compilers, compiler support past 128 bits varies. |
| `bin` | `bool` | Boolean. |
| `chr` | `char` | Character. |
| `str` | `char*` | Null-terminated string. |
| `raw` | `void` (`raw*` for `void*`) | Opaque type. |

### `nil`

The null pointer/string sentinel (a keyword; lowers to C `NULL`). It
coerces to any pointer type and to `str`, and compares with `==`/`!=`:
`num* p = nil;`, `if p == nil { ... }`, `Node{next = nil}`. No import is
needed, unlike the C macro `NULL`, which requires `imp std.c.def;`.

### Raw strings

A backtick-delimited literal (`` `...` ``) needs no escaping at all: a
backslash or an embedded double-quote is just a literal byte.

```fun
imp std.io;

fun main() {
  let path = `C:\Users\name\file.txt`;
  let msg = `she said "hi" and left`;
  println_fmt("path={str}", path);
  println_fmt("msg={str}", msg);
}
```

Two forms, both starting with a backtick, disambiguated purely by whether
you close it on the same line:

- **Inline**: closed by another backtick on the same line (as above).
- **Multi-line**: a backtick left unclosed before the line's newline
  starts a block. Each subsequent line that begins (after leading
  whitespace) with its own backtick contributes its own content, joined
  with a real newline byte, ending at the first line that doesn't:

```fun
imp std.io;

fun main() {
  let sql =
    `SELECT *
    `FROM users
    `WHERE id = ?
  ;
  println_fmt("sql={str}", sql);
}
```

Trailing code that needs to sit on the same line as the last content line
can close the block explicitly instead: `` `WHERE id = ?`; ``.

A literal backtick is written as two (` `` `), the one escape a raw
string has. A single backtick still closes the string, so `` `` `` on its
own is the empty raw string, and content that is itself made of backticks
(a markdown fence, for one) is written by doubling each:

```fun
imp std.io;

fun main() {
  let quoted = `a``b`;          // a`b
  let fence = ```````fun`;      // ```fun
  println_fmt("quoted={str}", quoted);
  println_fmt("fence={str}", fence);
}
```

### Arrays

Array literals require uniform element types: `num[] arr = [1, 2, 3];`.

### Pointers

Pointer depth is written `Type*`: `Node* next;`. Self-referential and
forward-declared types are supported.

## Variables

Variables can be explicitly typed or inferred with `let`.

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

### Type inference (`let`)

`let` always requires an initializer; the compiler infers the declared
type from the expression:

- Numeric literals infer `num` or `dec` depending on literal form:
  `1` -> `num`, `1.5` -> `dec`.
- `"text"` infers `str`, `'a'` infers `chr`, `true`/`false` infer `bin`.
- Array literals infer element type and become `T[]`: `[1, 2, 3]` ->
  `num[]`, `[Point{x = 1, y = 2}]` -> `Point[]`.
- Function calls infer the function's return type: `let p =
  make_point(1, 2);` -> `Point`.
- Member access uses the receiver's type: `let x = p.x;` -> `num`.
- Indexing an array yields its element type: `let v = nums[i];` -> `num`
  when `nums` is `num[]`.
- If the expression mixes numeric types, inference prefers the wider
  category (`dec` over `num`).

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

`const` declares an immutable binding, at top level or local scope:
`const MAX = 10;` (inferred, like `let`) or `const num MAX = 10;`
(explicit type). Both forms always require an initializer. `pub const`
exports a top-level constant. Reassigning a `const` (directly or via a
compound-assignment operator like `+=`) is a compile-time typecheck
error, for both local and global constants:

```fun
const num MAX = 100;

fun main() {
  const local_max = MAX;
  MAX = 200;        // error: cannot assign to const 'MAX'
  local_max += 1;    // error: cannot assign to const 'local_max'
}
```

## Enums

```fun
enum Color { Red, Green, Blue }

fun main() {
  Color c = .Red;
  _ = c;
}
```

- **Longhand access**: `Color.Red` (works even if the enum is declared
  later in the file).
- **Shorthand access**: `.Red` (contextual; the expected enum type must
  be known from assignment, argument, or `fit`).
- **Function arguments**: `fun takes(Color c) { ... }` called as
  `takes(.Blue);`.
- **Pattern matching**: `fit c { .Red -> { ... }, .Green -> { ... }, _ ->
  { ... } }`, or the longhand form `Color.Red -> { ... }`.
- **Exhaustiveness**: missing enum variants in `fit` may emit
  `fit_non_exhaustive`; redundant branches or catch-alls may emit
  `fit_unreachable_branch`.

### Data-carrying enums (sum types / tagged unions)

A variant may carry a positional payload, turning the enum into a tagged
union. An enum becomes a tagged union as soon as *any* variant has a
payload; payload-free variants still coexist.

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

- A payload is a parenthesized, comma-separated list of types. Payloads
  can be primitives, compounds (by value), or monomorphized generic
  instances (`Boxed(Box<num>)`).
- Construction: longhand `Shape.Circle(5)`, shorthand `.Circle(5)` when
  the expected type is known, or `Shape.Empty` for a payload-free
  variant.
- Pattern matching destructures the payload into locals visible in the
  arm body; a `_ -> { ... }` catch-all covers the remaining variants.
- A tagged-union enum lowers to a C `struct { Enum_tag tag; union { ...
  } payload; }`; payload-free (plain) enums keep the classic C `enum`
  lowering.
- The same `fit_non_exhaustive` check applies: cover every variant or add
  a `_` catch-all.

### Option/Result Propagation

Sugar over `std.option`/`std.result`, replacing the repeated
check-then-unwrap shape with a single postfix operator:

```fun
imp std.option;
imp std.result;

fun half(num x) Option<num> {
  if x % 2 == 1 { ret .None; }
  ret .Some(x / 2);
}

fun to_result(num x) Result<num, str> {
  if x < 0 { ret .Err("negative"); }
  ret .Ok(x);
}

fun combine(num x) Option<num> {
  num a = half(x)?;         // .None short-circuits: returns .None here
  ret .Some(a + 1);
}

fun combine_result(num x) Result<num, str> {
  num a = to_result(x)!;    // .Err(e) short-circuits: returns .Err(e) here
  ret .Ok(a + 1);
}
```

- `expr?` unwraps an `Option<T>`: `.Some(v)` evaluates to `v`; `.None`
  returns `.None` from the enclosing function immediately. The enclosing
  function must itself return `Option<...>`.
- `expr!` unwraps a `Result<T, E>`: `.Ok(v)` evaluates to `v`; `.Err(e)`
  returns `.Err(e)` from the enclosing function immediately. The
  enclosing function must return `Result<_, E>` with the exact same
  error type; there is no automatic conversion between error types.
- Both work anywhere an expression is legal, not just statement-final: a
  `let` initializer, a call argument, a chained access (`half(x)?.field`),
  nested inside another expression.
- `foo()!=x` still lexes as the `!=` comparison operator (a space-free
  `!` immediately before `=` always folds), so it never means "propagate,
  then compare"; write `foo()! == x` if propagation was intended.
- This is pure sugar: the equivalent `if`/`ret` form still works
  everywhere and is what these operators expand to.
- A propagation can also be used directly as a `fit` subject
  (`fit expr? { ... }`/`fit expr! { ... }`), with no intermediate `let`
  needed:

  ```fun
  fun describe(num x) Option<str> {
    fit half(x)? {
      0 -> { ret .Some("zero"); }
      _ -> { ret .Some("nonzero"); }
    }
  }
  ```

## Compounds & Quirks

Compounds are like C structs, and can have methods via `impl`.

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

### Private fields (leading `_`)

A compound field whose name begins with an underscore is
module-private: readable/writable only from code in the same module as
the compound's declaration (including its own `impl` methods via
`self._field`). Another module must go through public accessor methods.

```fun
imp std.io;

compound Account {
  num id;          // public
  num _balance;    // private to this module
}
impl Account {
  pub balance() num { ret self._balance; }   // ok: same module
}
// In another module: `acc._balance` is rejected; `acc.balance()` works.

fun main() {
  Account acc;
  acc.id = 1;
  acc._balance = 100;
  println_fmt("balance={num}", acc.balance());
}
```

### Quirks (interfaces)

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

- Quirk values can be used for dynamic dispatch, like trait objects.
- Quirk methods follow normal visibility rules: non-`pub` methods are
  callable inside the declaring module, but not from importing modules.
- Formatting with `{}` uses `Display.to_string()` only when that method
  is accessible at the call site. If `to_string()` is private in another
  module, formatting falls back to pointer-style output for that value.

### Implementations

```fun
imp std.io;

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
  println_fmt("p=({num},{num}) area={num}", p.x, p.y, r.area());
}
```

A plain `impl Point { ... }` attaches methods to a compound directly;
`impl Rectangle as Shape { ... }` implements a quirk for it.

### Generics

Compounds, impls, and free functions can be generic: `compound Vec<T> {
... }`, `fun identity<T>(T x) T { ret x; }`. Use `Vec<num>` etc. where a
concrete instantiation is required.

Type parameters can be constrained with `:` and `|`, on impls, compounds,
and free functions alike:

```fun
imp std.io;

// Named Accum here (not Vec) only to avoid colliding with std.vec's own
// Vec<T> for this standalone example; a real project would just use that.
compound Accum<T> {
  T[] data;
  num len;
}

impl Accum<T: num | dec> {
  pub sum(T zero) T {
    T out = zero;
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

fun main() {
  Accum<num> nums;
  nums.data = [1, 2, 3];
  nums.len = 3;
  println_fmt("sum={num} id={num}", nums.sum(0), identity(5));
}
```

This lets one body work for a fixed set of concrete types; the compiler
monomorphizes each concrete instantiation and rejects a call/instantiation
whose type argument isn't in the declared bound at compile time.

### Generic quirks

A quirk can be generic too: `quirk To<T> { to() T; }`, and `impl Point as
To<JsonValue> { pub to() JsonValue { ... } }` binds a concrete
instantiation.

- A concrete instantiation dispatches the same way a non-generic quirk
  does: a direct method call (`p.to()`), or a quirk-typed
  parameter/variable naming the same concrete instantiation
  (`fun to_json_value(To<JsonValue> value) JsonValue { ret value.to(); }`,
  called as `to_json_value(&p)`).
- Each concrete instantiation (`To<JsonValue>`, `To<num>`, ...) is its own
  quirk identity: an `impl` binds one specific instantiation, and a
  quirk-typed parameter/variable must name that same instantiation to
  dispatch.
- A still-generic reference to a quirk's own type parameter (`impl
  VecIter<T> as Iterator<T>`) is a different, symbolic binding that
  resolves through the enclosing type's own generic instantiation
  instead of naming one concrete type.

## Functions

```fun
imp std.io;

fun add(num a, num b) num {
  ret a + b;
}

fun main() {
  println_fmt("sum={num}", add(1, 2));
}
```

- No nested function declarations.
- `ret value;` returns from a function.
- Generic functions: `fun id<T>(T x) T { ret x; }`, type arguments
  inferred from call sites (`num v = id(1);`).

### Default parameter values

A parameter may declare a default with `= expr`; a call that omits it
uses the default.

```fun
imp std.io;

fun greet(str name, num times = 1, str sep = ", ") {
  println_fmt("name={str} times={num} sep={str}", name, times, sep);
}

fun main() {
  greet("a");           // times = 1, sep = ", "
  greet("a", 3);        // times = 3, sep = ", "
  greet("a", 3, "; ");  // all explicit
}
```

- **Trailing only**: defaulted parameters must come last, a required
  parameter cannot follow a defaulted one.
- **Self-contained defaults**: a default expression is evaluated at the
  call site, so it may not reference `self` or an earlier parameter (a
  constant, a global, `nil`, an enum variant, or another self-contained
  expression is fine).
- Works for free functions and methods, including generic, `async`, and
  pointer-receiver methods.

### Function values

`fun(T1, T2, ...) R` names the type of a function taking `T1, T2, ...`
and returning `R` (omit `R` for a `void` function). A function value is
written as a bare reference to a named function, and works as a
parameter, a local variable, a function's own return type, and a
compound field:

```fun
imp std.io;

fun add(num a, num b) num { ret a + b; }
fun apply(num a, num b, fun(num, num) num cb) num { ret cb(a, b); }
fun get_op() fun(num, num) num { ret add; }

compound Ops {
  fun(num, num) num op;
}

fun main() {
  println_fmt("result={num}", apply(2, 3, add)); // 5

  fun(num, num) num f = get_op();
  println_fmt("result={num}", f(4, 5)); // 9

  Ops o = .{op = add};
  println_fmt("result={num}", o.op(6, 7)); // 13
}
```

Every call site is checked against the declared signature: arity, every
parameter type, and the return type must match. This holds whether the
function value is passed by name as an argument, called through a
parameter inside the function that received it, or called through a
compound field, and a generic method's own type parameter (`Vec<T>`'s `T`
in `sort_by(cmp)`) is substituted with the receiver's real type first. A
mismatch is a compile error, caught before it can reach the C compiler.
`Vec<T>.sort_by(cmp)` is the standard library's own use of this, for
custom comparators.

### `missing_return`

A non-`void` function that can fall off the end without returning
triggers `missing_return`, always checked. The analysis is conservative:
a trailing `ret`, an exhaustive `if/elif/else` where every branch
returns, a `fit` with a default branch whose arms all return, and
infinite loops (`for {}`/`for true {}` with no `break`) all count as
returning.

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
- Indexed: `for i, item :: arr { ... }` (indexable sources only, arrays
  and `Vec`).
- Iterator: `for item : collection { ... }`, driving any value whose type
  implements the `Iterator` quirk (`next() Option<T>`) or exposes an
  `iter()` returning one. Desugars to the `next()`/`Option` protocol, so
  `Vec`, `Set`, and `Map` (keys) iterate directly.
- Map pairs: `for k, v :: map { ... }` binds each key to `k` and its
  value to `v`.
- While-style (condition): `for i < len { ... }`
- Infinite loop: `for true { ... }`

This style is common in the standard library (for example `std/string.fn`,
`std/net.fn`, and `std/fs.fn`).

### Fit (pattern matching)

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

Missing variants may produce `fit_non_exhaustive` unless `_` is present.
See Enums above for `fit` over data-carrying (tagged-union) enums.

`fit` matches one subject at a time; it has no multi-value/tuple form. A
comma inside one arm's condition (`0, 1 -> { ... }`) is not that - it's
an OR of several patterns against the same single subject. To match on
several values together, build a short combined key first and `fit` on
that:

```fun
str key = format("{chr}{chr}{chr}", a, b, c);
fit key {
  "str" -> { ... }
  "num" -> { ... }
  _ -> { ... }
}
```

which reads far more clearly than an `if a == .. && b == .. && c == ..
{ ... } elif ...` chain once there are more than two or three
combinations to cover.

## Defer

- **Purpose**: run cleanup logic automatically when the current lexical
  scope exits.
- **Order**: LIFO (last `defer` runs first).
- **Forms**: expression (`defer close(fd);`) or block (`defer { log("done");
  cleanup(); }`).
- **Scope semantics**: a `defer` runs when the scope where it appears
  exits; function-scope defers run before `ret` and before implicit
  function end; loop-body defers run at the end of each iteration; on
  `continue`/`break`, defers in the current loop iteration run before
  control leaves it.

## Inline Assembly

```fun
imp std.io;

fun main() {
  num x = 21 + 21;
  num y = 0;

  // `volatile` comes before `arch`. This runs when compiled on an
  // aarch64 host; an x86_64 build would instead use:
  //   asm volatile arch x86_64 (out y: "=r" = y; in x: "r" = x; clobber "memory") {
  //     movq %[x], %[y]
  //   };
  asm volatile arch aarch64 (out y: "=r" = y; in x: "r" = x; clobber "memory") {
    mov %[y], %[x]
  };

  println_fmt("y={num}", y);
}
```

- **Block form**: `asm { ... };`. **String form**: `asm "...";` (use this
  for exact formatting/escapes).
- **Volatile**: `asm volatile { ... };` prevents reordering/elision.
- **Architecture guard**: `asm arch x86_64 { ... };` errors if the target
  arch mismatches. Supported names: `x86_64`/`amd64`, `x86`/`i386`,
  `aarch64`/`arm64`, `arm`.
- **Operands & clobbers**: reference named operands in templates with
  `%[name]`. Outputs come first, then inputs, then clobbers (GCC-style
  extended asm).
- Asm block contents are preserved as raw text (including whitespace and
  comments). Fun does not validate assembly syntax inside asm blocks;
  correctness is decided by the downstream assembler/dialect (clang/GAS
  vs NASM, for example).

### Inline assembly pitfalls

- **ISA mismatch**: AArch64 register names (`x0`) will not assemble on
  x86_64. Guard by arch.
- **Operand order**: x86_64 uses `movq src, dst` (AT&T syntax) while
  AArch64 uses `mov dst, src`.
- **Missing size suffix**: x86_64 `mov` needs a size suffix
  (`movb`/`movw`/`movl`/`movq`).
- **Implicit clobbers**: if the asm touches memory not listed in
  operands, include `"memory"`.
- **Named receiver errors**: if you move values into locals via asm,
  ensure `out` targets are assigned to named locals.
- Example: `jmp $` may fail under clang/GAS inline asm; label form like
  `1: ... jmp 1b` is typically more portable in that pipeline.

## Imports & Modularity

- **Standard library**: `imp std.c.io;` maps to C standard headers;
  `imp std.string;` imports Fun-native stdlib modules.
- **Relative imports**: `imp ..foo.bar;` for user modules.
- **Import alias**: `imp mod1 as one;`, then call symbols as
  `one.some_fn()`.
- **Duplicate export collisions**: import modules that export the same
  public symbol by aliasing each module and calling through the alias
  namespace:

```fun
// file: mod1.fn
pub fun pick() num { ret 1; }

// file: mod2.fn
pub fun pick() num { ret 2; }

// file: main.fn
imp std.io;
imp mod1 as one;
imp mod2 as two;

fun main() {
  num a = one.pick();
  num b = two.pick();
  println_fmt("a={num} b={num}", a, b);
}
```

- **Circular dependency detection**: the compiler detects and errors on
  circular imports.

## C Interop

- **C macros**: ALL_CAPS identifiers (`NULL`, `INT_MAX`) are allowed if
  the right header is imported.
- **Direct mapping**: `imp std.c.*;` maps to C headers (`stdio.h`,
  `limits.h`, etc.). Fun stdlib modules under `std.c.*` only declare
  signatures; C provides the implementations.
- **Printf formats**: `num` is `int64_t` in C. Use `PRId64` (from
  `<inttypes.h>`) or cast to `long long` with `%lld` when printing.

See Platforms & Compilers for C compiler selection and per-platform
behavior.

## Error Handling

- Type mismatches, undeclared symbols, duplicate declarations, missing
  imports, and incomplete quirk implementations are compile errors.
- Pointer-return, `fit` exhaustiveness, redundant `fit` branches,
  unreachable statements, constant assertions, and optional unused-*
  diagnostics are emitted as warnings (see [Warning Controls](#language?anchor=language-warning-controls) below).

## Warning Controls

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
- `missing_return`: a non-`void` function/method that can reach the end
  of its body without returning a value. Always checked, not gated
  behind `-warn-unused`.
- `blocking_fork_deadlock` (with `-warn-unused`): a `WaitGroup` created
  with a literal `wait_group_new(0)` (whose internal signal buffer holds
  only one completion) is `done()`'d from tasks spawned by `fork` inside
  a loop; the producer can block before any receiver drains it. Size the
  WaitGroup to the task count.
- `shared_mutable_capture_race` (with `-warn-unused`): a mutable compound
  with no internal `Mutex`/`Channel` field is passed by `&` into a
  mutating `async fun` that is `fork`ed multiple times (e.g. in a loop),
  so several tasks mutate the same value without synchronization. Guard
  it with a `Mutex` or give each task its own copy. `Channel`/
  `WaitGroup` (self-synchronizing) are exempt.
- `integer_literal_out_of_range` (with `-warn-unused`): a compile-time
  integer literal cannot be represented in the declared arbitrary-width
  integer type, a value larger than the type's width (`u2 x = 5;`, `i6 y
  = 100;`), or a negative value assigned to an unsigned `uN` (`u8 z =
  -3;`).
- `channel_capacity_overflow` (with `-warn-unused`): more blocking sends
  are issued into a bounded channel than its capacity with no concurrent
  receiver, so the producer blocks forever (e.g. `let c =
  channel_new_cap(0, 1); c <- 1; c <- 2; c <- 3;`). Conservative: only
  fires when the capacity and the send count are statically known
  literals, the channel is never received-from, and no `fork` runs
  first.

### Control statements

- `allow <warning_id>, "reason";` suppresses the next emitted warning
  with that ID.
- `expect <warning_id>, "reason";` also suppresses the next warning with
  that ID, but compilation fails if no such warning is emitted later.

`allow`/`expect` are statement directives that work inside function
bodies; `unused_variable`, `unused_import`, `unused_function`, and
`unused_compound` may also be controlled at module scope for the next
top-level declaration or import. The reason string is required and
documents why the warning is being allowed/expected.

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
- examples/error_cases/warning_expect_unmet.fn (expected compile failure)

## Example

```fun
imp std.io;

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
  println_fmt("p=({num},{num})", p.x, p.y);
}
```

## Additional Features

- **Forward declarations**: compounds can reference each other
  regardless of order.
- **Self-referential types**: supported via pointers.
- **Exhaustive and non-exhaustive pattern matching**: with a `_` default
  branch.
- **CLI tooling**: compile, transpile, and run Fun code from the command
  line, see Tooling for the full reference.
