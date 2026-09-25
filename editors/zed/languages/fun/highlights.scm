(comment) @comment

; Keywords
[
  "use"
  "fun"
  "als"
  "as"
  "impl"
  "quirk"
  "compound"
  "enum"
  "let"
  "const"
  "async"
  "await"
  "fork"
  "defer"
  "asm"
  "volatile"
  "arch"
  "test"
  "fuzz"
  "sequential"
  "allow"
  "expect"
  "assert"
  "panic"
  "sizeof"
] @keyword

(visibility) @keyword

[
  "if"
  "elif"
  "else"
  "for"
  "fit"
  "ret"
  "break"
  "continue"
] @keyword

; Types
(primitive_type) @type.builtin
((type_identifier) @type.builtin
  (#match? @type.builtin "^[iu][1-9][0-9]*$"))
(type_identifier) @type
(module) @namespace

; Declarations
(function_declaration name: (identifier) @function)
(method_declaration name: (identifier) @function.method)
(enum_variant name: (identifier) @constant)
(field_declaration name: (identifier) @property)
(parameter name: (identifier) @variable.parameter)
(alias_declaration name: (type_identifier) @type)
(use_declaration alias: (identifier) @namespace)

; Expressions
(call_expression function: (identifier) @function)
(call_expression function: (field_expression field: (identifier) @function.method))
(generic_call_expression function: (identifier) @function)
(generic_call_expression function: (field_expression field: (identifier) @function.method))
(field_expression field: (identifier) @property)
(field_expression field: (tuple_index) @number)
(field_initializer name: (identifier) @property)
(enum_shorthand_expression variant: (identifier) @constant)
(variant_pattern variant: (identifier) @constant)
(variant_pattern enum: (identifier) @type)
(wildcard_pattern) @variable.special
(warning_control id: (identifier) @attribute)

((identifier) @constant
  (#match? @constant "^[A-Z][A-Z0-9_]+$"))

((identifier) @variable.special
  (#eq? @variable.special "self"))

(identifier) @variable

; Literals
(number_literal) @number
[
  (boolean_literal)
  (nil_literal)
] @constant.builtin
(string_literal) @string
(raw_string_literal) @string
(char_literal) @string
(escape_sequence) @string.escape
(asm_body) @embedded

; Operators and punctuation
[
  "="
  "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>="
  "==" "!=" "<" "<=" ">" ">="
  "&&" "||" "!" "~" "&" "|" "^" "<<" ">>"
  "+" "-" "*" "/" "%"
  "++" "--" ".." "->" "::" "<-"
  "?" "!?" "?!"
] @operator

[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket
[ ";" "," "." ":" ] @punctuation.delimiter
