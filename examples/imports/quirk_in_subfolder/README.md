Minimal repro for LSP autocomplete + diagnostics with quirks split across files.

- `defs/greeter.fn` declares `quirk Greeter`.
- `user.fn` declares `compound User`.
- `user_greeter.fn` implements `impl User Greeter { ... }`.
- `main.fn` imports everything and should autocomplete:
  - `User` and `Greeter` names
  - `u.` members (`greet`, `bye`)

If `impl User Greeter` is missing any required quirk methods, `fls` diagnostics should report an error.
