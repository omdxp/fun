" Fun Web colorscheme (matches the reference website code palette)

hi clear
if exists("syntax_on")
  syntax reset
endif

let g:colors_name = "funweb"
set background=dark

hi Normal       guifg=#E8EDFF guibg=#0A1228 ctermfg=231 ctermbg=17
hi Comment      guifg=#7F8DB8 ctermfg=103
hi String       guifg=#F1C38F ctermfg=223
hi Character    guifg=#F1C38F ctermfg=223
hi Number       guifg=#9DE0FF ctermfg=153
hi Boolean      guifg=#FFB3C0 ctermfg=217
hi Keyword      guifg=#7AA2FF gui=bold ctermfg=111 cterm=bold
hi Statement    guifg=#7AA2FF gui=bold ctermfg=111 cterm=bold
hi Type         guifg=#9BDC8A ctermfg=114
hi Typedef      guifg=#B6A6FF ctermfg=183
hi Special      guifg=#7FE0C1 ctermfg=122
hi Function     guifg=#A9E4FF ctermfg=159
hi Identifier   guifg=#A9E4FF ctermfg=159
hi Operator     guifg=#8FB3FF ctermfg=111

hi CursorLine   guibg=#0D1630 ctermbg=18
hi Visual       guibg=#355AAD ctermbg=25
hi LineNr       guifg=#5A6EA8 guibg=#0A1228 ctermfg=60 ctermbg=17
hi CursorLineNr guifg=#9CB1E9 guibg=#0A1228 ctermfg=147 ctermbg=17
