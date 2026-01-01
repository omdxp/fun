# fun Examples

This directory contains example programs for the fun language.

- `test.fn` — Basic syntax and features
- `advanced/` — Advanced language features
- `imports/` — Import and module system
- `error_cases/` — Error handling and edge cases
- `stdlib/` — Real-world-ish examples for `imp std.*;`

## New examples

- `advanced/fit_exhaustive_warning.fn` — Triggers a warning for non-exhaustive `fit` on `bin`
- `advanced/fit_exhaustive_ok.fn` — Exhaustive `fit` on `bin` (no warning)

Try running these with the fun CLI to see the language in action!

## Standard library examples

- `stdlib/io_file_copy.fn` — Uses `std.io` file I/O (`fopen`, `fputc`, `perror`)
- `stdlib/mem_env_random.fn` — Uses `std.mem` (`getenv`, `strtol`, `malloc`, `memset`, `free`)
- `stdlib/string_parse_csv_line.fn` — Uses `std.string` (`strlen`, `strstr`, `strcmp`)
- `stdlib/math_distance.fn` — Uses `std.math` (`sqrt`)
- `stdlib/ctype_validate_identifier.fn` — Uses `std.ctype` (`isalpha`, `tolower`, etc.)
- `stdlib/time_format_now.fn` — Uses `std.time` (`time`, `ctime`)

## CLI examples

- `cli_args.fn` — Read program args via `main(argc, argv)`
