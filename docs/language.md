# fun Language Reference

## Syntax
- Statically-typed, C-inspired
- Functions: `fun name(args) type { ... }`
- Imports: `imp std.io;`
- Pattern matching: `fit x { ... }`

## Types
- `num` (integer number), `dec` (decimal number), `str` (string), `bin` (boolean), `chr` (character)

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
