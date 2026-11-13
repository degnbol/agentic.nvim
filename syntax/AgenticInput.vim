if exists('b:current_syntax')
  finish
endif

syn match AgenticSlashCommandPrefix "^/\ze[[:alnum:]_-]\+\%(\s\|$\)" nextgroup=AgenticSlashCommand
syn match AgenticSlashCommand "[[:alnum:]_-]\+" contained

let b:current_syntax = 'AgenticInput'
