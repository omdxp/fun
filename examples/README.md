# fun Examples

This directory contains example programs for the Fun language.

Run any example:
```sh
zig-out/bin/fun -in examples/<example>.fn
```

## Basics
- c_file_io.fn
- c_limits_and_null.fn
- c_size_t.fn
- cli_args.fn
- defer.fn
- enum_defined_after_main.fn
- enum_dot_shorthand.fn
- enum_fit_catch_all.fn
- enum_fit_non_exhaustive.fn
- enum_showcase.fn
- enums.fn
- plain_impl.fn
- return_heap_ptr_ok.fn
- return_local_ptr_warning.fn
- sizeof_all_types.fn
- test.fn
- test_circular.fn
- type_order.fn

## Advanced
- advanced/chr.fn
- advanced/custom_functions.fn
- advanced/dec.fn
- advanced/assert_with_message.fn
- advanced/fit_exhaustive_ok.fn
- advanced/fit_exhaustive_warning.fn
- advanced/for_loops.fn
- advanced/asm_basic.fn
- advanced/asm_operands.fn
- advanced/asm_arch_specific.fn
- advanced/quirks.fn

## Imports
- imports/main.fn
- imports/nested/deep_import.fn
- imports/relative/parent.fn
- imports/parent_traversal_2up/nested/level1/main.fn
- imports/impl_across_files/main.fn
- imports/quirk_across_folders/main.fn
- imports/quirk_in_subfolder/main.fn

## Standard library
- stdlib/array_helpers.fn
- stdlib/assert_basic.fn
- stdlib/cli_parse.fn
- stdlib/ctype_validate_identifier.fn
- stdlib/compound_init.fn
- stdlib/error_basic.fn
- stdlib/io_file_copy.fn
- stdlib/io_read_write.fn
- stdlib/io_format.fn
- stdlib/print_fmt_varargs.fn
- stdlib/json_basic.fn
- stdlib/log_levels.fn
- stdlib/map_basic.fn
- stdlib/math_distance.fn
- stdlib/math_helpers.fn
- stdlib/mem_env_random.fn
- stdlib/net_url_parse.fn
- stdlib/option_basic.fn
- stdlib/path_ops.fn
- stdlib/rand_basic.fn
- stdlib/result_basic.fn
- stdlib/set_basic.fn
- stdlib/string_helpers.fn
- stdlib/string_parse_csv_line.fn
- stdlib/time_format_now.fn
- stdlib/time_helpers.fn
- stdlib/toml_basic.fn
- stdlib/vec_basic.fn
- stdlib/array_helpers.fn
- stdlib/cli_parse.fn
- stdlib/io_read_write.fn
- stdlib/json_basic.fn
- stdlib/log_levels.fn
- stdlib/map_basic.fn
- stdlib/math_helpers.fn
- stdlib/net_url_parse.fn
- stdlib/path_ops.fn
- stdlib/rand_basic.fn
- stdlib/set_basic.fn
- stdlib/string_helpers.fn
- stdlib/time_helpers.fn
- stdlib/toml_basic.fn
- stdlib/vec_basic.fn

## Visibility (pub)
- pub_visibility/main.fn
- pub_visibility/private_access.fn (expected error: accessing private declarations)

## Error cases
- error_cases/already_declared_variable.fn
- error_cases/duplicate_symbols.fn
- error_cases/functions_cannot_be_declared_inside_functions.fn
- error_cases/missing_import.fn
- error_cases/quirk_impl_missing_methods.fn
- error_cases/type_mismatch.fn
- error_cases/undeclared_symbols.fn
- error_cases/undeclared_symbols_arguments.fn
- error_cases/undeclared_symbols_in_specific_scopes.fn
- error_cases/undeclared_symbols_recursive.fn
- error_cases/circular_dependency/circular1.fn
- error_cases/circular_dependency/circular2.fn
- error_cases/duplicate_symbols/mod1.fn
- error_cases/duplicate_symbols/mod2.fn
