if exists("b:current_syntax")
  finish
endif

" Mirrors editors/vscode/syntaxes/fun.tmLanguage.json, so the two highlight
" the same source the same way. Later items win over earlier ones that
" match at the same position, so more specific rules come last.

syn match funOperator "\v(->|::|\+\=|-\=|\*\=|/\=|\%\=|\=\=|!\=|\<\=|\>\=|\&\&|\|\||\<\<|\>\>|\+\+|--|[+\-*/%=<>!?&|^~.])"
syn match funOperator "\v[;,:]"

syn match funNumber "\v<(0x[0-9a-fA-F]+|\d+(\.\d+)?)>"

syn match funCustomType "\v<[A-Z][A-Za-z0-9_]*>\ze\s*(\*+)?\s*[A-Za-z_][A-Za-z0-9_]*>"
syn match funCustomType "\v<[A-Z][A-Za-z0-9_]*>\ze\s*\<"
syn match funCustomType "\v<(compound|shape|enum|impl)\s+\zs[A-Za-z_][A-Za-z0-9_]*>"

" A call, a call spelling out its own generic type arguments
" (`identity<str>(5)`, lowercase only, so a downcast arm like
" `Box<num>(b) ->` stays a type), and a declaration's own name.
syn match funFunction "\v<[A-Za-z_][A-Za-z0-9_]*>\ze\s*\("
syn match funFunction "\v<[a-z_][A-Za-z0-9_]*>\ze\s*\<([^<>()]|\<[^<>()]*\>)*\>\s*\("
syn match funFunction "\v<fun\s+\zs[A-Za-z_][A-Za-z0-9_]*>"

syn match funKeyword "\<packed\ze\s\+compound\>"
syn keyword funKeyword use as pub fun closure als compound shape impl enum let const asm volatile arch defer ret if elif else for fit async await fork break continue assert panic test sequential fuzz allow expect
syn keyword funType void raw num dec f32 f64 str flag chr
syn match funType "\v<(i|u)[1-9][0-9]*>"
syn keyword funSupportType size_t ptrdiff_t ssize_t intptr_t uintptr_t int8_t uint8_t int16_t uint16_t int32_t uint32_t int64_t uint64_t time_t clock_t
syn keyword funBoolean true false
syn keyword funConstant nil

syn region funString start=+"+ skip=+\\\\\|\\"+ end=+"+
syn region funChar start=+'+ skip=+\\\\\|\\'+ end=+'+

" Raw strings. Inline: closed by a single backtick on the same line, a
" doubled backtick being the one escape (a literal backtick). Multi-line:
" a backtick left unclosed on its line starts a block; each continuation
" line begins (after leading whitespace) with its own backtick marker,
" and the block ends at an explicit single closing backtick (code may
" follow it on that line) or at the first line with no marker. `skip`
" steps over markers and doubled backticks so neither ends the block.
syn region funRawBlock start=+`\ze\%(``\|[^`]\)*$+ skip=+^\s*`\|``+ end=+`\|^\%(\s*`\)\@!+
syn match funRawString +`\%(``\|[^`]\)*`+

syn match funComment "//.*$"
syn region funComment start=+/\*+ end=+\*/+

hi def link funKeyword Keyword
hi def link funType Type
hi def link funCustomType Typedef
hi def link funSupportType Special
hi def link funFunction Function
hi def link funBoolean Boolean
hi def link funConstant Constant
hi def link funOperator Operator
hi def link funNumber Number
hi def link funString String
hi def link funRawString String
hi def link funRawBlock String
hi def link funChar Character
hi def link funComment Comment

let b:current_syntax = "fun"
