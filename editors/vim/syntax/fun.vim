if exists("b:current_syntax")
  finish
endif

syn keyword funKeyword imp as pub fun compound quirk impl enum let asm volatile arch defer ret if elif else for fit async await break continue assert allow expect
syn keyword funType void raw num dec f32 f64 str bin chr
syn match funType "\v\<(i|u)[1-9][0-9]*\>"
syn match funCustomType "\v\<(compound|quirk|enum|impl)\s+\zs[A-Za-z_][A-Za-z0-9_]*\>"
syn match funCustomType "\v\<[A-Za-z_][A-Za-z0-9_]*\ze\s*<[^>]+>"
syn match funCustomType "\v\<[A-Z][A-Za-z0-9_]*\>\ze\s*(\*+)?\s*[A-Za-z_][A-Za-z0-9_]*\>"
syn keyword funSupportType size_t ptrdiff_t ssize_t intptr_t uintptr_t int8_t uint8_t int16_t uint16_t int32_t uint32_t int64_t uint64_t time_t clock_t
syn keyword funBoolean true false

syn match funNumber "\v\d+(\.\d+)?"
syn region funString start=+"+ skip=+\\"+ end=+"+
syn region funChar start=+'+ skip=+\\'+ end=+'+
syn match funComment "//.*$"

hi def link funKeyword Keyword
hi def link funType Type
hi def link funCustomType Typedef
hi def link funSupportType Special
hi def link funBoolean Boolean
hi def link funNumber Number
hi def link funString String
hi def link funChar Character
hi def link funComment Comment

let b:current_syntax = "fun"
