(function_declaration
  (visibility)? @context
  "fun" @context
  name: (_) @name) @item

(method_declaration
  (visibility)? @context
  name: (_) @name) @item

(compound_declaration
  (visibility)? @context
  "compound" @context
  name: (_) @name) @item

(enum_declaration
  (visibility)? @context
  "enum" @context
  name: (_) @name) @item

(quirk_declaration
  (visibility)? @context
  "quirk" @context
  name: (_) @name) @item

(impl_declaration
  "impl" @context
  type: (_) @name) @item

(alias_declaration
  (visibility)? @context
  "als" @context
  name: (_) @name) @item

(test_declaration
  "test" @context
  name: (_) @name) @item

(fuzz_declaration
  "fuzz" @context
  name: (_) @name) @item
