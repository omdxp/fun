# Fun Examples

This directory contains runnable examples covering the language core, standard library, import system, diagnostics, and edge-case behavior. The examples are organized so you can move from foundational syntax to advanced concurrency, generics, and tooling-oriented scenarios.

## Running Examples

After building the compiler, run any example directly:

```sh
zig-out/bin/fun -in examples/<example>.fn
```

## Suggested Reading Order

- Start with the basic examples to understand declarations, control flow, enums, and type behavior.
- Move to `advanced/` for async, channels, generics, warnings, and lower-level features.
- Use `imports/` to understand multi-file organization and module resolution.
- Use `stdlib/` for practical standard-library usage patterns.
- Use `error_cases/` when working on diagnostics, parser behavior, or negative tests.

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
- let_and_lowlevel_types.fn
- let_inference_edge_cases.fn
- let_quirk_explicit_ok.fn
- main_exit_status.fn
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
- advanced/async_quirk_await_function_receiver.fn
- advanced/async_quirk_await_generic_wrapper.fn
- advanced/generic_inference_after_init.fn
- advanced/async_quirk_await_indexed_receiver.fn
- advanced/async_quirk_await_nested_receiver.fn
- advanced/async_quirk_await_parenthesized_receiver.fn
- advanced/async_quirk_await_pointer_receiver.fn
- advanced/channel_async_composed.fn
- advanced/async_runtime_threads_channels.fn
- advanced/async_thread_clock_ticks.fn
- advanced/async_spawn_join_handle.fn
- advanced/channel_buffered.fn
- advanced/channel_select2.fn
- advanced/channel_select3_rr.fn
- advanced/channel_single_slot.fn
- advanced/channel_timeout.fn
- advanced/thread_pool_zero_workers.fn
- advanced/warning_allow.fn
- advanced/warning_expect.fn
- advanced/return_local_ptr_allow.fn
- advanced/unused_variable_warning.fn
- advanced/unused_variable_allow.fn
- advanced/unused_variable_expect.fn
- advanced/unused_import_warning.fn
- advanced/unused_import_allow.fn
- advanced/unused_import_expect.fn
- advanced/unused_function_warning.fn
- advanced/unused_function_allow.fn
- advanced/unused_function_expect.fn
- advanced/unused_compound_warning.fn
- advanced/unused_compound_allow.fn
- advanced/unused_compound_expect.fn
- advanced/fit_unreachable_branch_warning.fn
- advanced/unreachable_code_warning.fn
- advanced/assert_constant_warning.fn
- advanced/quirks.fn
- advanced/const_bindings.fn
- advanced/explicit_generic_call.fn
- advanced/raw_string_literal.fn
- advanced/method_own_type_param.fn
- advanced/test_blocks_demo.fn

## Imports
- imports/main.fn
- imports/alias_collision/main.fn
- imports/async_quirk_alias/main.fn
- imports/alias_module_scope.fn
- imports/nested/deep_import.fn
- imports/relative/parent.fn
- imports/parent_traversal_2up/nested/level1/main.fn
- imports/impl_across_files/main.fn
- imports/private_quirk_scope/main.fn
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
- stdlib/io_async_pipeline.fn
- stdlib/io_format.fn
- stdlib/print_fmt_varargs.fn
- stdlib/json_basic.fn
- stdlib/json_values_iter.fn
- stdlib/log_levels.fn
- stdlib/sys_try_env_log_alias.fn
- stdlib/map_basic.fn
- stdlib/map_custom_strategy.fn
- stdlib/map_num_keys.fn
- stdlib/math_distance.fn
- stdlib/math_helpers.fn
- stdlib/math_rand_option_aliases.fn
- stdlib/math_ops.fn
- stdlib/mem_env_random.fn
- stdlib/net_url_parse.fn
- stdlib/net_async_composition.fn
- stdlib/option_basic.fn
- stdlib/path_ops.fn
- stdlib/rand_basic.fn
- stdlib/result_basic.fn
- stdlib/set_basic.fn
- stdlib/serde_json_toml.fn
- stdlib/string_helpers.fn
- stdlib/string_parse_csv_line.fn
- stdlib/fs_async_streaming.fn
- stdlib/time_format_now.fn
- stdlib/time_helpers.fn
- stdlib/toml_basic.fn
- stdlib/vec_basic.fn
- stdlib/vec_constrained_generic_impl.fn

## Visibility (pub)
- pub_visibility/main.fn
- pub_visibility/private_access.fn (expected error: accessing private declarations)

## Error cases
- error_cases/already_declared_variable.fn
- error_cases/duplicate_symbols.fn
- error_cases/functions_cannot_be_declared_inside_functions.fn
- error_cases/let_infer_enum_dot_ambiguous.fn
- error_cases/let_infer_quirk_invalid.fn
- error_cases/missing_import.fn
- error_cases/private_quirk_method_access.fn
- error_cases/quirk_impl_missing_methods.fn
- error_cases/type_mismatch.fn
- error_cases/undeclared_symbols.fn
- error_cases/undeclared_symbols_arguments.fn
- error_cases/undeclared_symbols_in_specific_scopes.fn
- error_cases/undeclared_symbols_recursive.fn
- error_cases/warning_expect_unmet.fn
- error_cases/circular_dependency/circular1.fn
- error_cases/circular_dependency/circular2.fn
- error_cases/duplicate_symbols/mod1.fn
- error_cases/duplicate_symbols/mod2.fn
