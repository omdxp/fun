if exists("b:current_syntax")
  finish
endif

syn keyword funKeyword imp as pub fun compound quirk impl enum let asm volatile arch defer ret if elif else for fit break continue assert allow expect
syn keyword funType void raw num dec f32 f64 str bin chr
syn match funType "\v\<(i|u)[1-9][0-9]*\>"
syn keyword funBoolean true false

syn match funNumber "\v\d+(\.\d+)?"
syn region funString start=+"+ skip=+\\"+ end=+"+
syn region funChar start=+'+ skip=+\\'+ end=+'+
syn match funComment "//.*$"

hi def link funKeyword Keyword
hi def link funType Type
hi def link funBoolean Boolean
hi def link funNumber Number
hi def link funString String
hi def link funChar Character
hi def link funComment Comment

let b:current_syntax = "fun"
