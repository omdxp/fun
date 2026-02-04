if exists("b:current_syntax")
  finish
endif

syn keyword funKeyword imp pub fun compound quirk impl enum asm volatile arch defer ret if elif else for fit break continue assert
syn keyword funType void raw num dec str bin chr
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
