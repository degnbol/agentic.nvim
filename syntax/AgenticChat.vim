if exists('b:current_syntax') | finish | endif

" NOTE: This file is NOT automatically sourced for chat buffers.
" Chat buffers are created with nvim_create_buf() (scratch buffers) and
" setting filetype via nvim_set_option_value does not trigger syntax file
" loading. Highlight links that must always apply go in theme.lua instead.
"
" Additionally, vim.treesitter.start(buf, "markdown") sets bo.syntax = "",
" which disables all syn match/region rules even if this file were sourced.

let b:current_syntax = 'AgenticChat'
