# fun Language Reference

## Syntax
- Statically-typed, C-inspired
- Functions: `fun name(args) type { ... }`
- Imports: `imp std.io;`
- Compounds: `compound Point { num x; num y; }`
- Quirks (interfaces): `quirk Shape { area() num; }`
- Implementations:
    - Quirk impl: `impl Rectangle Shape { ... }`
    - Plain compound methods: `impl Point { translate(num dx, num dy) { ... } }`
- Pattern matching: `fit x { ... }`

## Types
- `num` (integer number), `dec` (decimal number), `str` (string), `bin` (boolean), `chr` (character)
- `raw` (opaque/"void" type; use `raw*` for C-style `void*`)

### Declaration Order
- `compound` types can reference other `compound` types even if those types are declared later in the file.
- This includes pointer fields like `Node* next;` (self-referential pointers are supported).
- By-value cycles (A contains B contains A by value) cannot be represented as C structs; use pointers to break cycles.

See [examples/type_order.fn](../examples/type_order.fn).

## Example
```fun
fun add(num a, num b) num {
    ret a + b;
}
```

## Control Flow
- `if`, `elif`, `else`
- `fit` (pattern matching)

## More
See [examples](../examples/) for real code.
