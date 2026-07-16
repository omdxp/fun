" Fun Web Light colorscheme (matches the reference website code palette)

hi clear
if exists("syntax_on")
  syntax reset
endif

let g:colors_name = "funweblight"
set background=light

hi Normal       guifg=#1B2340 guibg=#F6F8FF ctermfg=236 ctermbg=231
hi Comment      guifg=#6A78A0 ctermfg=103
hi String       guifg=#9A5B12 ctermfg=130
hi Character    guifg=#9A5B12 ctermfg=130
hi Number       guifg=#1F6F9E ctermfg=24
hi Boolean      guifg=#C0325A ctermfg=125
hi Keyword      guifg=#2F5BD0 gui=bold ctermfg=26 cterm=bold
hi Statement    guifg=#2F5BD0 gui=bold ctermfg=26 cterm=bold
hi Type         guifg=#2E7D32 ctermfg=28
hi Typedef      guifg=#6A4FD0 ctermfg=62
hi Special      guifg=#0E8A6E ctermfg=29
hi Function     guifg=#1E7FA8 ctermfg=31
hi Identifier   guifg=#1E7FA8 ctermfg=31
hi Operator     guifg=#3F63C0 ctermfg=25

hi CursorLine   guibg=#EEF2FF ctermbg=255
hi Visual       guibg=#B9CCF5 ctermbg=153
hi LineNr       guifg=#9AA6D0 guibg=#F6F8FF ctermfg=146 ctermbg=231
hi CursorLineNr guifg=#4A5A90 guibg=#F6F8FF ctermfg=60 ctermbg=231
