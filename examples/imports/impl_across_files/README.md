# Impl Across Files Example

This example validates method resolution and editor completion when a compound and its implementation are declared in separate files.

## Structure

- `user.fn` declares `compound User`
- `user_impl.fn` declares `impl User { greet() }`
- `main.fn` imports both files and exercises method completion

## What This Example Verifies

- the implementation is associated with `User` across file boundaries
- editor completion on `u.` includes `greet()` for a `User*`
- language tooling resolves methods consistently when declarations and implementations are split across modules
