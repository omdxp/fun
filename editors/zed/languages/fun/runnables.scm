(
  (function_declaration
    name: (identifier) @run
    (#eq? @run "main")) @_fn
  (#set! tag fun-main)
)

(
  (test_declaration
    name: (string_literal (string_content) @run @test_name)) @_test
  (#set! tag fun-test)
)

(
  (fuzz_declaration
    name: (string_literal (string_content) @run @fuzz_name)) @_fuzz
  (#set! tag fun-fuzz)
)
