if exists('b:current_syntax') | finish | endif

" Sourced via deferred vim.bo.syntax = "ON" in ftplugin/AgenticChat.lua,
" after vim.treesitter.start(buf, "markdown") clears bo.syntax.

syn match AgenticSlashCommandPrefix "^/" nextgroup=AgenticSlashCommand
syn match AgenticSlashCommand "[[:alnum:]_-]\+" contained

syn match AgenticMentionPrefix "@\ze[[:alnum:]_.~/$]" nextgroup=AgenticMention
syn match AgenticMention "[[:alnum:]_.~/$][^ \t]*" contained

let b:current_syntax = 'AgenticChat'
