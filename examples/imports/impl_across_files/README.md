Minimal repro for LSP method completion across files.

- `user.fn` declares `compound User`.
- `user_impl.fn` declares `impl User { greet() }`.
- `main.fn` imports both and should complete `u.greet()` after typing `u.` (where `u` is a `User*`).
