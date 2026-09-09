if exists("b:current_syntax")
  finish
endif

syn keyword funKeyword imp as pub fun compound quirk impl enum let const asm volatile arch defer ret if elif else for fit async await fork break continue assert panic test fuzz allow expect
syn keyword funType void raw num dec f32 f64 str bin chr
syn match funType "\v\<(i|u)[1-9][0-9]*\>"
syn match funCustomType "\v\<(compound|quirk|enum|impl)\s+\zs[A-Za-z_][A-Za-z0-9_]*\>"
syn match funCustomType "\v\<[A-Za-z_][A-Za-z0-9_]*\ze\s*<[^>]+>"
syn match funCustomType "\v\<[A-Z][A-Za-z0-9_]*\>\ze\s*(\*+)?\s*[A-Za-z_][A-Za-z0-9_]*\>"
syn match funOperator "\v(->|::|\+=|-=|\*=|/=|==|!=|<=|>=|&&|\|\||<<|>>|\+\+|--|[+\-*/%=<>!?&|^~.])"
syn match funOperator "%="
syn match funOperator "\v[;,:]"
syn keyword funSupportType size_t ptrdiff_t ssize_t intptr_t uintptr_t int8_t uint8_t int16_t uint16_t int32_t uint32_t int64_t uint64_t time_t clock_t
syn keyword funBoolean true false
syn keyword funConstant nil

syn match funNumber "\v\d+(\.\d+)?"
syn region funString start=+"+ skip=+\\"+ end=+"+
syn region funChar start=+'+ skip=+\\'+ end=+'+
" Raw (backtick) string: no escape processing at all -- the closing
" backtick, whenever it's found (possibly several lines later for a
" multi-line block), ends the literal.
syn region funRawString start=+`+ end=+`+
syn match funComment "//.*$"
syn region funComment start=+/\*+ end=+\*/+

hi def link funKeyword Keyword
hi def link funType Type
hi def link funCustomType Typedef
hi def link funSupportType Special
hi def link funBoolean Boolean
hi def link funConstant Constant
hi def link funOperator Operator
hi def link funNumber Number
hi def link funString String
hi def link funRawString String
hi def link funChar Character
hi def link funComment Comment

let b:current_syntax = "fun"
