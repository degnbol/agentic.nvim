if exists('b:current_syntax') | finish | endif

" Sourced via deferred vim.bo.syntax = "ON" in ftplugin/AgenticChat.lua,
" after vim.treesitter.start(buf, "markdown") clears bo.syntax.

" Slash commands are highlighted only at line start (^/) because line-start
" /command is intercepted by the CLI before the LLM sees it (built-in, skill,
" or unknown). Mid-line /word has no special meaning — it's plain prose. The
" highlight signals "intercepted and acted upon" vs unmarked text.
syn match AgenticSlashCommandPrefix "^/\ze[[:alnum:]_-]\+\%(\s\|$\)" nextgroup=AgenticSlashCommand
syn match AgenticSlashCommand "[[:alnum:]_-]\+" contained

syn match AgenticMentionPrefix "@\ze[[:alnum:]_.~/$]" nextgroup=AgenticMention
syn match AgenticMention "[[:alnum:]_.~/$][^ \t]*" contained

let b:current_syntax = 'AgenticChat'
