(
  (function_declaration
    name: (identifier) @run
    (#eq? @run "main")) @_fn
  (#set! tag fun-main)
)

(
  (test_declaration
    name: (string_literal (string_content) @run)) @_test
  (#set! tag fun-test)
)
