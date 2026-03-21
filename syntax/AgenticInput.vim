if exists('b:current_syntax')
  finish
endif

syn match AgenticSlashCommandPrefix "^/" nextgroup=AgenticSlashCommand
syn match AgenticSlashCommand "[[:alnum:]_-]\+" contained

syn match AgenticMentionPrefix "@" nextgroup=AgenticMention
syn match AgenticMention "[^ \t]\+" contained

let b:current_syntax = 'AgenticInput'
