# agentic.nvim

A Claude-focused AI chat interface for Neovim via [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).

## Features

### Rendering

- Bash-formatted shell commands (`shfmt` + treesitter injection)
- Grep/search output colouring — paths, line numbers, separators, match highlights
- Diff preview for edits (inline or split, `]c`/`[c` to navigate hunks)
- Fold markers for long tool output (`zo`/`zc`/`za`)
- Sign-column block decorations
- Slash-command and `@`-mention syntax highlighting
- Native neovim text wrapping and yanking — no hard-wraps, no copy-paste surprises

### Permissions

- `/trust` — per-session auto-approval scope for file-scoped edits, layered with git-recoverability, symlink, and TOCTOU safety
- Auto-approve read-only tools (Read/Grep/Glob) regardless of target path
- Compound Bash command auto-approval — splits `foo | bar && baz` and checks each segment against `settings.json`. Works around upstream [anthropics/claude-code#16561](https://github.com/anthropics/claude-code/issues/16561)
- Allow/reject-always cache — ACP does not reliably persist these
- Permission keys `1`-`5` with escalating severity (reject-all-queued vs reject-always)

### Session & workflow

- Multi-tabpage — one session per tabpage, fully isolated
- Auto-continue scheduled after usage-limit reset
- Attention bell/badge when chat is unfocused or scrolled up
- Auto-scroll with runtime toggle (`<localLeader>a`)
- Todos / code / files / diagnostics panels alongside chat
- External UI hook (`AgenticHeadersChanged` autocmd + `vim.t.agentic_headers`) for plugins like incline.nvim

See `:help agentic-vs-tui` for a full comparison — including which TUI-only commands are patched through ACP locally, and which TUI features aren't available here.

## Requirements

- Neovim v0.11.0+
- `claude-agent-acp` -- install via `pnpm add -g @zed-industries/claude-agent-acp` or [download a binary](https://github.com/zed-industries/claude-agent-acp/releases)

Other ACP providers (Gemini, Codex, OpenCode, Cursor Agent, Auggie, Mistral Vibe) also work -- see `config_default.lua` for the full list.

## Setup

```lua
require("agentic").setup({
    provider = "claude-agent-acp",
    -- ... any overrides
})
```

All options with defaults: [`lua/agentic/config_default.lua`](lua/agentic/config_default.lua).

## Documentation

Full reference: `:help agentic`

## Debug mode

```lua
require("agentic").setup({ debug = true })
```

View logs with `:messages` or in `~/.cache/nvim/agentic_debug.log`.

## Licence

[MIT](LICENSE.txt)

Based on [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim). Built on the [Agent Client Protocol](https://agentclientprotocol.com).
