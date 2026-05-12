# agentic.nvim

An AI chat interface via [Agent Client Protocol (ACP)](https://agentclientprotocol.com) in neovim.
Experimental support for other models through opencode.

Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).

## Features

See `:help agentic-vs-tui` for a comparison to e.g. Claude TUI.

### Session & workflow

- One session per tabpage
- Auto-continue scheduled after usage-limit reset (WIP)
- Attention bell/badge when chat is unfocused or scrolled up
- Auto-scroll toggle (default: `<localLeader>a`)
- Todos / code / files / diagnostics panels alongside chat
- External UI hook (`AgenticHeadersChanged` autocmd + `vim.t.agentic_headers`) for plugins like [incline.nvim](https://github.com/b0o/incline.nvim)
- `:w[rite]` of your input prompt submits it (by default).
  - Opt-in register copy via `settings.send_register`.
  - Partial prompt submit (similar to Claude Code stash functionality.
    - `<CR><CR>` sends the current line (with count), `<CR>{motion}` sends the motion range, visual `<CR>` sends the selection.
  - Set new keymaps for the submission of common custom prompts. Comes with `<localLeader>c` to send "Continue"
- Completion of any terms mentioned in chat
- Navigation keymap (default: `[[` and `]]`) for cursor jump between prompts.
- `:AgenticResume {query}` — open a cached session by `session_id` prefix or exact title (case-insensitive). Opens a tab via `toggle_tab` and sends `session/load` to the agent. With `session_restore.cd_on_load` (default `true`), nvim's working directory is changed to the session's recorded cwd.
- **Forwarded slash commands** (work via ACP, not intercepted locally):
  - `/init` — generate a project `CLAUDE.md`
  - `/review` — pull-request review
  - `/security-review` — security review of pending changes
  - `/compact`, `/extra-usage`, `/insights`, `/team-onboarding`, `/heapdump`

### Rendering

- Bash-formatted shell commands (`shfmt` + treesitter injection)
- Grep/search output colouring — paths, line numbers, separators, match highlights
- Markdown tables aligned column-by-column
- Diff preview for edits (inline and side-by-side split view)
- Native vim folding for long tool output
- Sign-column block decorations
- Prose stream formatting when using nowrap.

### Permissions

- Compound Bash command auto-approval — splits `foo | bar && baz` and checks each segment against Claude's `settings.json`.
- `/trust` — per-session auto-approval scope for file-scoped edits, layered with git-recoverability, symlink, and TOCTOU safety
- Auto-approve read-only tools (Read/Grep/Glob) regardless of target path
- A cache for selection of "Always allow/reject"

## Requirements

- Neovim v0.11.0+
- ACP provider(s)
  - Claude: [`claude-agent-acp`](https://github.com/agentclientprotocol/claude-agent-acp). install via e.g.
    - `npm install -g @agentclientprotocol/claude-agent-acp` or
    - `pnpm add -g @agentclientprotocol/claude-agent-acp` or
    - [download](https://github.com/agentclientprotocol/claude-agent-acp/releases)
  - opencode
  - ...

### Treesitter parsers

Install the `bash` or `zsh` parser for shell command highlighting in chat. See `:help agentic-requirements-parsers`.

### OpenCode permission caveat

OpenCode is trust-by-default: `edit`, `bash`, and most other tools auto-approve unless you opt in via its config. To route permission prompts through this plugin, set in `~/.config/opencode/opencode.json` (or `config.json`):

```json
{
  "permission": {
    "edit": "ask",
    "bash": "ask"
  }
}
```

If you want to guard against prompt injection through fetched web content (a returned page persuading the agent to execute follow-up actions), also set `"webfetch": "ask"`.

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

## Licence

[MIT](LICENSE.txt)

Based on [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim). Built on the [Agent Client Protocol](https://agentclientprotocol.com).
