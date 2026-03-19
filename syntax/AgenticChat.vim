if exists('b:current_syntax') | finish | endif

" Status footer patterns (icon + status text)
syn match AgenticStatusCompleted /\s*\S\s\+completed\s*/ contains=NONE
syn match AgenticStatusFailed    /\s*\S\s\+failed\s*/    contains=NONE
syn match AgenticStatusPending   /\s*\S\s\+pending\s*/   contains=NONE
syn match AgenticStatusPending   /\s*\S\s\+in_progress\s*/ contains=NONE

hi def link AgenticStatusCompleted AgenticStatusCompleted
hi def link AgenticStatusFailed    AgenticStatusFailed
hi def link AgenticStatusPending   AgenticStatusPending

let b:current_syntax = 'AgenticChat'
