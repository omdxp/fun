# Quirk Across Subfolders Example

This example validates import resolution, quirk implementation discovery, autocomplete, and diagnostics when a quirk definition and its implementation are split across multiple files and subfolders.

## Structure

- `defs/greeter.fn` declares `quirk Greeter`
- `user.fn` declares `compound User`
- `user_greeter.fn` implements `impl User as Greeter { ... }`
- `main.fn` imports the pieces and exercises editor tooling behavior

## What This Example Verifies

- `User` and `Greeter` resolve correctly across the import graph
- member completion on `u.` includes quirk-provided members such as `greet` and `bye`
- diagnostics report an error when the `User as Greeter` implementation is missing required quirk methods
