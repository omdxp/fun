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
use std.io;

// Optional value container. Named Maybe here (not Option) only to avoid
// colliding with std.option's own Option<T> for this standalone example.
pub compound Maybe<T> {
  // True when a value is present.
  flag has;
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
  println_fmt("has={flag} value={num}", opt.has, opt.value);
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
| `flag` | `bool` | Boolean. |
| `chr` | `char` | Character. |
| `str` | `char*` | Null-terminated string. |
| `raw` | `void` (`raw*` for `void*`) | Opaque type. |

### `nil`

The null pointer/string sentinel (a keyword; lowers to C `NULL`). It
coerces to any pointer type and to `str`, and compares with `==`/`!=`:
`num* p = nil;`, `if p == nil { ... }`, `Node{next = nil}`. No import is
needed, unlike the C macro `NULL`, which requires `use std.c.def;`.

### Raw strings

A backtick-delimited literal (`` `...` ``) needs no escaping at all: a
backslash or an embedded double-quote is just a literal byte.

```fun
use std.io;

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
use std.io;

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
use std.io;

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

### Tuples

`(T1, T2, ...)` groups two or more differently-typed values into one
real type, usable anywhere a type is: a variable's declared type, a
function parameter or return type, or a generic argument - with no
separate `compound` declaration needed.

```fun
use std.io;

fun min_max(num a, num b) (num, num) {
  if a < b {
    ret (a, b);
  }
  ret (b, a);
}

fun main() {
  (num, str) person = (30, "Ada");
  println_fmt("{num} {str}", person.0, person.1);

  let (low, high) = min_max(9, 3);
  println_fmt("{num} {num}", low, high);
}
```

- A tuple **literal** needs at least two comma-separated elements:
  `(1, "hi")`. A single parenthesized value (`(1)`) stays an ordinary
  grouped expression, not a one-element tuple.
- Read an element back **positionally** with `.0`, `.1`, and so on; an
  out-of-range index is a compile-time error. A tuple-of-tuples chains
  directly - `t.0.1` reads element `1` of `t`'s own element `0` - even
  though `0.1` would otherwise lex as one decimal number: the compiler
  splits it back into two positional hops from the token's own raw
  source digits, not its parsed value, so a multi-digit chained index
  (`t.0.10`) still reads back correctly as element `10`, not `1`.
- **`let (a, b, c) = expr;`** destructures a tuple into individually-
  typed names in one step. `expr` is evaluated exactly once no matter
  how many names it destructures into, and each name must actually be
  used or it's an `unused_variable` warning like any other local
  (prefix with `_` to opt out, same convention as elsewhere).
- **`(T1, T2) (a, b) = expr;`** destructures with an explicit declared
  type instead of inferring one, the same way `dec x = 1;` declares a
  type rather than inferring it: each name gets its own declared
  element type, and `expr` must fit the declared type as a whole
  (numeric widening included), not just whatever it happens to infer to.
- **`for (a, b) : pairs { ... }`** destructures each element of a
  tuple-elemented iterable (`Vec<(K, V)>`) into its own names per
  iteration, the same way `let` destructures a plain tuple value - no
  combined index-tracking form (`for (a, b) :: xs` is not supported;
  the existing `for i, item :: xs` two-name form already covers index
  tracking).
- A tuple works as an ordinary generic argument (`Box<(num, str)>`) and
  as an ordinary type alias's own body - see [Type Aliases](#type-aliases)
  for the `als Args = (num, str);` pattern this enables with generic
  aliases.
- **`fit`** matches a tuple subject structurally: `(0, y) -> ...` matches
  when element `0` equals `0`, binding `y` to element `1`. Each position
  is independent - a bare (non-`_`) identifier binds that position's own
  value, `_` matches without binding, and anything else (a literal, or
  any other expression) is a guard that position's own value must equal.
  A later branch is only reached when an earlier one's guard positions
  don't all match:
  ```fun
  fun main() {
    (num, str) t = (0, "go");
    fit t {
      (0, s) -> { println_fmt("zero, {str}", s); }
      (n, s) -> { println_fmt("{num}, {str}", n, s); }
    }
  }
  ```

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
- `"text"` infers `str`, `'a'` infers `chr`, `true`/`false` infer `flag`.
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
  let b = true;              // flag
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
use std.option;
use std.result;

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

### Cross-type propagation: `?!`/`!?`

`?`/`!` only ever propagate a matching signal: an inner `.None` becomes
an outer `.None`, an inner `.Err(e)` becomes an outer `.Err(e)`. `?!`
and `!?` bridge the other direction, between `Option` and `Result`:

```fun
fun find(num x) Option<num> {
  if x > 0 { ret .Some(x); }
  ret .None;
}

fun combine(num x) Result<num, str> {
  num a = find(x)?!("not found");  // .None -> .Err("not found") here
  ret .Ok(a + 1);
}

fun parse(num x) Result<num, str> {
  if x > 0 { ret .Ok(x); }
  ret .Err("bad");
}

fun safe_parse(num x) Option<num> {
  num a = parse(x)!?;              // .Err(_) -> .None here, discarded
  ret .Some(a * 2);
}
```

- `expr?!(err)` unwraps an `Option<T>`: `.Some(v)` evaluates to `v`;
  `.None` returns `err` from the enclosing function immediately, wrapped
  in whatever shape it needs - `.Err(err)` if it returns `Result<_, E>`,
  or `.Some(err)` if it returns `Option<E>` (the error-channel
  convention where `.Some` carries the error and `.None` means success).
  `err` must exactly match that slot's own type, the same
  no-conversion discipline `!` already has.
- `expr!?` unwraps a `Result<T, E>`: `.Ok(v)` evaluates to `v`; `.Err(_)`
  returns `.None` from the enclosing function immediately, discarding
  the error entirely. The enclosing function must return `Option<...>`;
  no relationship between its own generic argument and `E` is required,
  since `.None` carries no payload.
- Each operator asks for exactly what it structurally needs: `?!` takes
  an argument because conjuring an error value from nothing isn't
  possible; `!?` takes none because discarding one needs nothing.
  Reading order is mnemonic: `?!` starts Option-side and ends
  Result/error-shaped ("this is optional, missing means this error");
  `!?` starts Result-side and ends Option-shaped ("this can fail, I
  only care whether it worked").
- Same rules as `?`/`!`: pure sugar for the equivalent `if`/`ret` form,
  works anywhere an expression is legal (a `let` initializer, a call
  argument, a chained access, a `fit` subject), and both operators are
  their own single tokens - `expr?!(err)`/`expr!?` never collide with
  anything else, the way a space-free `!=` folds ahead of `?`/`!`.

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
use std.io;

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
use std.io;

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
use std.io;

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
whose type argument isn't in the declared bound at compile time. A bound
alternative can also name a quirk instead of a concrete type, checked by
"does this type implement it" rather than an exact match, or be a full type
expression like a generic instantiation (`T: User | Vec<num>`), not just a
bare identifier - a bound list is a union of concrete types, quirks, and
type expressions, mixed freely.

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
  Vec<T> as Iterator<T>`) is a different, symbolic binding that
  resolves through the enclosing type's own generic instantiation
  instead of naming one concrete type.

### Type Aliases

`als Name<T1, T2> = <type>;` names a reusable type expression, expanded
wherever it's referenced before typechecking ever runs - the compiler
never sees the alias name itself, only its fully-resolved body, so it's
never a textual macro: the underlying type is still fully enforced.

```fun
use std.io;

// A non-generic alias: just a shorter, more meaningful name.
als Meters = num;

// A generic alias whose body is a function type.
als Callback<A, R> = fun(A) R;

fun square(num x) num {
  ret x * x;
}

fun apply(Callback<num, num> cb, num x) num {
  ret cb(x);
}

// A bound-list alias: stands for a union of types, spliced into a
// generic constraint wherever it's referenced.
als Numeric = num | dec;

fun double<T: Numeric>(T x) T {
  ret x + x;
}

fun main() {
  Meters distance = 5;
  println_fmt("distance={num} applied={num} doubled={num}", distance, apply(square, 4), double(3));
}
```

- An alias can be `pub`, same as any other top-level declaration.
- An alias's own body can reference another alias (`als Top = Middle;`);
  a reference cycle among aliases is a compile-time error, not infinite
  recursion.
- **An alias's own body can never be a pointer type**
  (`als NodePtr = Node*;` is rejected, and so is a pointer-typed
  alternative in a bound-list alias's own body): the point of writing
  `Node* x;` is that the pointer is visible right there at the use site,
  not hidden behind a name that reads like an ordinary value. Applying a
  pointer at a *reference* to a non-pointer alias (`Meters* m;`) is
  unaffected - the pointer is still written explicitly there, exactly
  like any other type.
- A bound-list alias (the `a | b` form) can't itself be generic - it has
  no single instantiation site of its own the way an ordinary alias does.
- An alias's own body can name a quirk (`als Drawable = Shape;`), and
  dynamic dispatch through it works exactly like a plain quirk-typed
  variable: `Drawable d = &square;` then `d.area()`. This is still a
  value type, not a pointer - `Drawable*` follows the same explicit-
  pointer-at-the-use-site rule as any other alias.
- An alias's own body can be a [tuple](#tuples) (`als Args = (num,
  str);`), and it's then an ordinary generic type parameter like any
  other: `als Callback<A, R> = fun(A) R;` plus `Callback<Args, str>`
  expands to `fun((num, str)) str` - no special-casing needed anywhere
  once tuples themselves exist.
- A type param written in parentheses in the alias's own declaration
  (`als Callback<(Args), Ret> = fun(Args) Ret;`) is a **spread** param:
  when it's bound to a tuple and fills a whole `fun(...)` parameter
  position in the alias's body, that tuple's own members spread into
  separate positional parameters instead of staying one tuple-struct
  parameter. `Callback<(num, dec, str), str>` expands to `fun(num, dec,
  str) str`, matching a hand-written variable-arity function signature.
  A bare (non-parenthesized) param bound to the same tuple stays a
  single tuple-struct parameter, as above - the parentheses at the
  declaration, not the argument's own shape, decide which.

## Functions

```fun
use std.io;

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
use std.io;

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
use std.io;

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

- Array: `for item : arr { ... }`
- Indexed array: `for i, item :: arr { ... }`
- While-style (condition): `for i < len { ... }`
- Infinite loop: `for true { ... }`
- Everything else - a range, `Vec`, `Map`, `Set`, or any user-defined
  type - iterates through the `Iterator<T>` quirk, below.

A raw C array (`num[] arr`) is the one special case: it iterates by
direct index, since it's a primitive language construct with no quirk
impls of its own. Every other iterable dispatches structurally through
`Iterator<T>`.

#### Iterator\<T\>

```fun
pub quirk Iterator<T> {
  next() Option<T>;
}
```

Any type implementing `Iterator<T>` directly works with `for` - no
`.iter()` indirection, no wrapper type. `for x : v { ... }` checks
whether `v`'s own type implements `Iterator<Elem>` and, if so, splices
that type's own `next()` body directly into the loop (full inlining,
not a per-element function call): a yielded `.Some(x)` becomes binding
the loop variable(s) and running the loop body; `.None` ends the loop.

`Range` (`for i : a..b { ... }`, needs `use std.range;`), `Vec<T>`,
`Map<K, V>` (`Iterator<(K, V)>`, yielding key/value pairs), and `Set<T>`
all implement `Iterator<T>` this way already; so does any type you write
yourself:

```fun
use std.option;

compound Countdown { num n; }

impl Countdown as Iterator<num> {
  pub next() Option<num> {
    if self.n <= 0 { ret .None; }
    self.n = self.n - 1;
    ret .Some(self.n + 1);
  }
}

fun main() {
  Countdown c = Countdown{n = 3};
  for x : c {
    // 3, 2, 1
  }
}
```

**Binding forms**, driven by the iterable's own `Elem` type (`T` in
`Iterator<T>`):

- One name (`for x : it { ... }`): `x` binds to `Elem` directly. For
  `Map`, that means the whole `(K, V)` pair.
- Two names (`for a, b :: it { ... }`): if `Elem` is itself a 2-tuple
  (as `Map`'s is), `a`/`b` bind to its two fields - this is how
  `for k, v :: someMap { ... }` gets a real key and value, not a pair.
  Otherwise, it enumerates: `a` is a running 0-based count, `b` is
  `Elem` - the same form arrays already use.
- Destructuring (`for (a, b) : it { ... }`): binds `Elem`'s own tuple
  fields by position, same arity/type rules as an ordinary `let`
  destructure. Works over any `Iterator` whose `Elem` is a tuple, not
  just `Map`.

**Reentrancy**: a `for` loop always iterates a fresh copy of the value
it started from, never the caller's own variable - a type implementing
`Iterator<T>` directly typically needs a cursor field of its own (like
`Vec<T>`'s `__iter_pos`), and this copy-before-iterate rule is what lets
two independent loops over "the same" value, or one nested inside
another over the same value, not corrupt each other's position. Driving
`.next()` manually (outside a `for` loop) advances the real value's own
cursor directly, with no such protection - the same as calling any
other mutating method.

This style is common in the standard library (for example `std/string.fn`,
`std/net.fn`, and `std/fs.fn`).

#### Steppable\<T\> and StepRange\<T\>

`Range` (above) is fixed to `num`, backing the `a..b` syntax sugar - that
stays exactly as it is. For a range over any other ordered type (dates,
a custom counter, ...), implement `Steppable<T>` and use `StepRange<T>`
directly; there's no `..` syntax for it, only explicit construction.

```fun
pub quirk Steppable<T> {
  succ() T;
  reached(T end) flag;
}
```

`Steppable<T>` is self-referential the same way `Iterator<T>` is:
`impl MyType as Steppable<MyType>` binds the quirk's own `T` to the
implementing type itself, so `succ()` returns a real, concrete `MyType`
with no separate `Self` keyword needed.

```fun
use std.step_range;
use std.c.io;

compound Day { num n; }

impl Day as Steppable<Day> {
  pub succ() Day {
    Day d;
    d.n = self.n + 1;
    ret d;
  }
  pub reached(Day end) flag { ret self.n >= end.n; }
}

fun main() {
  Day start = Day{n = 1};
  Day end = Day{n = 5};
  for d : StepRange<Day>{start = start, end = end} {
    printf("day %lld\n", d.n); // day 1, day 2, day 3, day 4
  }
}
```

`StepRange<T: Steppable<T>>` implements `Iterator<T>` the same way `Range`
does, so every binding form and the reentrancy guarantee above apply to
it unchanged.

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
use std.io;

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

- **Standard library**: `use std.c.io;` maps to C standard headers;
  `use std.string;` imports Fun-native stdlib modules.
- **Relative imports**: `use ..foo.bar;` for user modules.
- **Import alias**: `use mod1 as one;`, then call symbols as
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
use std.io;
use mod1 as one;
use mod2 as two;

fun main() {
  num a = one.pick();
  num b = two.pick();
  println_fmt("a={num} b={num}", a, b);
}
```

- **Circular dependency detection**: the compiler detects and errors on
  circular imports.
- **Imports are transitive.** `use std.io;` alone also resolves every
  name `std.io`'s own imports declare (`std.c.io`'s `putchar`,
  `std.vec`'s `Vec<T>`, and so on), not just `std.io`'s direct public
  API. This is intentional: the whole `use`-connected graph is merged
  into one flat program before typecheck and codegen ever run, the
  same way a `#include`-based build sees everything a header
  transitively pulls in. There is no per-file "only what I directly
  imported" visibility boundary, and none is planned - it would mean
  giving every file its own scoped symbol table, a structural change
  disproportionate to the mild "completion offers a name I didn't
  import directly" symptom this currently produces.
- **A private (non-`pub`) top-level name must be unique across the
  whole compiled program, not just within its own file.** Two files
  each declaring their own private `_collect` conflict:
  `'_collect' is already declared as a function in a.fn:1`. This is
  intentional too, for the same reason: the merged program is one flat
  namespace, and true per-module privacy would need every private
  name's own C symbol mangled with its declaring file, which is a wide
  change for real code that already works around this today the same
  way most C code does - a project-specific prefix (`_mymod_collect`)
  on a private helper whose bare name would otherwise collide. The
  diagnostic names the exact conflict and where, so the fix (rename, or
  make one `pub`) is immediate.

## C Interop

- **C macros**: ALL_CAPS identifiers (`NULL`, `INT_MAX`) are allowed if
  the right header is imported.
- **Direct mapping**: `use std.c.*;` maps to C headers (`stdio.h`,
  `limits.h`, etc.). Fun stdlib modules under `std.c.*` only declare
  signatures; C provides the implementations.
- **Printf formats**: `num` is `int64_t` in C. Use `PRId64` (from
  `<inttypes.h>`) or cast to `long long` with `%lld` when printing.
- **C's own reserved words** (`do`, `int`, `for`, `void`, ...) can't
  name a plain top-level function, a function parameter, or a `let`/
  `const`/global variable - none of these are reserved in Fun itself,
  but each is emitted to C verbatim, so a collision would fail C
  compilation rather than Fun's own. Caught at parse time with a clear
  error instead. A generic function's own name is exempt: it always
  monomorphizes with its concrete type arguments (`double<T>` becomes
  `double__num`, `double__dec`, ...), so it never actually reaches C
  bare - `fun double<T: num | dec>(T x) T { ret x + x; }` is fine.

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
- `unused_type_alias` (with `-warn-unused`)
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
  with that ID, then stops - a later occurrence of the same ID reports
  normally again.
- `allow <warning_id>s, "reason";` (the plural spelling of the same ID)
  suppresses every emitted warning with that ID for the rest of the
  file, not just the next one.
- `expect <warning_id>, "reason";` / `expect <warning_id>s, "reason";`
  follow the same singular/plural split, but compilation fails if that
  ID is never emitted at all.

`allow`/`expect` are statement directives that work inside function
bodies; `unused_variable`, `unused_import`, `unused_function`,
`unused_compound`, and `unused_type_alias` may also be controlled at
module scope, anywhere before the imports/declarations they cover. The
reason string is required and documents why the warning is being
allowed/expected. No warning ID needs a plural form registered by
hand: `unused_imports`, `unused_variables`, `fit_non_exhaustives`, and
so on all resolve automatically from the same ID's ordinary English
plural.

```fun
fun bad() num* {
  expect return_local_ptr, "tracked until allocator refactor";
  num x = 1;
  ret &x;
}

fun partial(flag x) {
  allow fit_non_exhaustive, "legacy branch set, cleanup pending";
  fit x {
    true -> { }
  }
}

fun noisy_helper() {
  // Every unused local in here is deliberate scaffolding, not just
  // the first one - the plural form covers the whole function.
  allow unused_variables, "scaffolding while wiring the real call sites";
  num a = 1;
  num b = 2;
}

fun main() {
  partial(true);
  num* p = bad();
  _ = p;
  noisy_helper();
}
```

See also:

- examples/advanced/warning_allow.fn
- examples/advanced/warning_expect.fn
- examples/advanced/warning_expect_plural.fn
- examples/advanced/return_local_ptr_allow.fn
- examples/advanced/unused_variable_warning.fn
- examples/advanced/unused_variable_allow.fn
- examples/advanced/unused_variable_expect.fn
- examples/advanced/unused_import_warning.fn
- examples/advanced/unused_import_allow.fn
- examples/advanced/unused_import_allow_plural.fn
- examples/advanced/unused_import_expect.fn
- examples/advanced/unused_function_warning.fn
- examples/advanced/unused_function_allow.fn
- examples/advanced/unused_function_expect.fn
- examples/advanced/unused_compound_warning.fn
- examples/advanced/unused_compound_allow.fn
- examples/advanced/unused_compound_expect.fn
- examples/advanced/unused_type_alias_warning.fn
- examples/advanced/unused_type_alias_allow.fn
- examples/advanced/unused_type_alias_expect.fn
- examples/advanced/fit_unreachable_branch_warning.fn
- examples/advanced/unreachable_code_warning.fn
- examples/advanced/assert_constant_warning.fn
- examples/error_cases/warning_expect_unmet.fn (expected compile failure)

## Example

```fun
use std.io;

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
