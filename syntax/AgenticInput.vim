if exists('b:current_syntax')
  finish
endif

syn match AgenticSlashCommandPrefix "^/\ze[[:alnum:]_-]\+\%(\s\|$\)" nextgroup=AgenticSlashCommand
syn match AgenticSlashCommand "[[:alnum:]_-]\+" contained

syn match AgenticMentionPrefix "@\ze[[:alnum:]_.~/$]" nextgroup=AgenticMention
syn match AgenticMention "[[:alnum:]_.~/$][^ \t]*" contained

let b:current_syntax = 'AgenticInput'
