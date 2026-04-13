# agentic.nvim

A Claude-focused AI chat interface for Neovim via [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).

## Features

- Tool call formatting with `shfmt` and bash syntax highlighting
- Search match and grep output colouring (file paths, line numbers, separators)
- Fold markers for long output (`zo`/`zc`/`za`)
- Sign-column block decorations via `sign_text` extmarks
- Slash command / `@` mention syntax highlighting
- Input buffer safeguards (`:wq`/`:x` interception)
- Compound command auto-approval -- splits `cd /path && git status` on shell operators and checks each segment against your `settings.json` allow/deny/ask rules, working around upstream [anthropics/claude-code#16561](https://github.com/anthropics/claude-code/issues/16561)
- Diff preview for edit tool calls (inline or split)
- Session persistence and restore

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
