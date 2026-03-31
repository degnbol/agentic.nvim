# agentic.nvim

A Claude-focused AI chat interface for Neovim via [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim) with enhanced tool call formatting and syntax highlighting.

## Fork differences

What this fork adds over upstream:

- **Tool call formatting** -- execute blocks use markdown code fences with bash syntax highlighting, formatted via `shfmt` (configurable)
- **Search match highlighting** -- pattern matches in search/grep output are highlighted (`AgenticSearchMatch`)
- **Grep output colouring** -- file paths, line numbers, and separators in grep-format output get distinct highlight groups
- **Fold markers for long output** -- search and execute output exceeding a threshold is auto-folded (vim-native `foldmethod=marker`), toggle with `zo`/`zc`/`za`
- **Sign-column block decorations** -- tool call borders use `sign_text` extmarks instead of inline virtual text (more stable during edits)
- **Slash command / `@` mention syntax** -- `/commands` and `@file` references are highlighted in both input and chat buffers
- **Input buffer safeguards** -- `:wq`/`:x` in the prompt buffer are intercepted to prevent accidental session close

## Requirements

- Neovim v0.11.0+
- `claude-agent-acp` -- install via `pnpm add -g @zed-industries/claude-agent-acp` or [download a binary](https://github.com/zed-industries/claude-agent-acp/releases)

Other ACP providers (Gemini, Codex, OpenCode, Cursor Agent, Auggie, Mistral Vibe) also work -- see `config_default.lua` for the full list.

## Configuration

All options with defaults: [`lua/agentic/config_default.lua`](lua/agentic/config_default.lua).

Only override what you need:

```lua
require("agentic").setup({
    provider = "claude-agent-acp",
    -- ... any overrides
})
```

## Lua API

| Function | Description |
|---|---|
| `require("agentic").toggle()` | Toggle chat sidebar |
| `require("agentic").toggle_tab()` | Toggle in dedicated tab |
| `require("agentic").open()` | Open chat sidebar |
| `require("agentic").close()` | Close chat sidebar |
| `require("agentic").send_prompt(text)` | Send text as prompt |
| `require("agentic").add_selection()` | Add visual selection to context |
| `require("agentic").add_file()` | Add current file to context |
| `require("agentic").add_selection_or_file_to_context()` | Add selection or file |
| `require("agentic").add_current_line_diagnostics()` | Add cursor line diagnostics |
| `require("agentic").add_buffer_diagnostics()` | Add all buffer diagnostics |
| `require("agentic").new_session()` | Start new session |
| `require("agentic").stop_generation()` | Stop current generation |
| `require("agentic").restore_session()` | Restore previous session |
| `require("agentic").switch_provider()` | Switch ACP provider |
| `require("agentic").rotate_layout()` | Rotate window position |

## Built-in keybindings

Set automatically in Agentic buffers:

| Key | Mode | Scope | Description |
|---|---|---|---|
| `<S-Tab>` | n/v/i | widget | Switch agent mode |
| `<C-c>` | n/i | widget | Stop generation |
| `<localLeader>c` | n | widget | Send "Continue" |
| `<localLeader>R` | n | widget | Restore session |
| `<localLeader>r` | n | widget | Refresh (scroll to bottom) |
| `<localLeader>s` | n | widget | Switch provider |
| `<localLeader>m` | n | widget | Switch model |
| `<localLeader>q` | n | widget | Close widget |
| `<localLeader>!` | n | widget | Restart session |
| `<CR>` | n | prompt | Submit |
| `<localLeader>p` | n | prompt | Paste image |
| `<C-v>` | i | prompt | Paste image |
| `[[` / `]]` | n | chat | Prev/next user prompt |
| `d` | n/v | panels | Remove item at cursor |
| `]c` / `[c` | n | diff | Next/prev diff hunk |
| `1`-`5` | n | widget | Permission responses (while prompt active) |

## Plug mappings

Global `<Plug>` mappings for binding from any buffer:

| Mapping | Mode | Description |
|---|---|---|
| `<Plug>(agentic-toggle)` | n | Toggle sidebar |
| `<Plug>(agentic-toggle-tab)` | n | Toggle in tab |
| `<Plug>(agentic-open)` | n | Open sidebar |
| `<Plug>(agentic-close)` | n | Close sidebar |
| `<Plug>(agentic-send)` | n/x | Send motion/selection |
| `<Plug>(agentic-send-line)` | n | Send current line |
| `<Plug>(agentic-add-file)` | n | Add file to context |
| `<Plug>(agentic-add-selection)` | x | Add selection |
| `<Plug>(agentic-add-diagnostics)` | n | Add cursor diagnostics |
| `<Plug>(agentic-add-buffer-diagnostics)` | n | Add all buffer diagnostics |
| `<Plug>(agentic-new-session)` | n | New session |
| `<Plug>(agentic-new-session-provider)` | n | New session with provider picker |
| `<Plug>(agentic-switch-provider)` | n | Switch provider |
| `<Plug>(agentic-restore-session)` | n | Restore session |
| `<Plug>(agentic-stop)` | n | Stop generation |
| `<Plug>(agentic-rotate-layout)` | n | Rotate layout |

## Highlight groups

Override these to match your colourscheme. All use `default = true`, so your definitions take priority.

| Group | Purpose | Default link |
|---|---|---|
| `AgenticDiffDelete` | Deleted lines in diff | `DiffDelete` |
| `AgenticDiffAdd` | Added lines in diff | `DiffAdd` |
| `AgenticDiffDeleteWord` | Word-level deletions | `DiffText` |
| `AgenticDiffAddWord` | Word-level additions | `DiffText` |
| `AgenticStatusPending` | Pending tool call | `DiagnosticVirtualTextHint` |
| `AgenticStatusCompleted` | Completed tool call | `DiagnosticVirtualTextOk` |
| `AgenticStatusFailed` | Failed tool call | `DiagnosticVirtualTextError` |
| `AgenticCodeBlockFence` | Code block fences | `NonText` |
| `AgenticToolKind` | Tool call kind heading | `Function` |
| `AgenticToolArgument` | Tool call argument | `String` |
| `AgenticSearchMatch` | Search pattern match | `Search` |
| `AgenticGrepPath` | File path in grep output | `@string.special.path` |
| `AgenticGrepLineNr` | Line number in grep output | `LineNr` |
| `AgenticGrepSeparator` | Separators in grep output | `Delimiter` |
| `AgenticSlashCommandPrefix` | `/` prefix | `@punctuation.special` |
| `AgenticSlashCommand` | Slash command body | `@function.call` |
| `AgenticMentionPrefix` | `@` prefix | `@punctuation.special` |
| `AgenticMention` | Mention body | `@string.special.path` |
| `AgenticErrorHeading` | Error heading | `DiagnosticError` |
| `AgenticErrorBody` | Error body | `DiagnosticVirtualTextError` |
| `AgenticSpinnerGenerating` | Generating spinner | `DiagnosticWarn` |
| `AgenticSpinnerThinking` | Thinking spinner | `Special` |
| `AgenticSpinnerSearching` | Searching spinner | `DiagnosticInfo` |
| `AgenticSpinnerBusy` | Busy spinner | `Comment` |
| `AgenticDimmedBlock` | Dimmed code fence lines | (set in ftplugin) |

## Health check

```vim
:checkhealth agentic
```

## Debug mode

```lua
require("agentic").setup({ debug = true })
```

View logs with `:messages` or in `~/.cache/nvim/agentic_debug.log`.

## Licence

[MIT](LICENSE.txt)

Based on [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim). Built on the [Agent Client Protocol](https://agentclientprotocol.com).
