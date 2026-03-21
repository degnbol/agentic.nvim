if exists('b:current_syntax')
  finish
endif

syn match AgenticSlashCommand "^/[[:alnum:]_-]\+"
syn match AgenticMention "@[^ \t]\+"

let b:current_syntax = 'AgenticInput'
