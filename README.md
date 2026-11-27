# agentic.nvim

An AI chat interface in neovim for the [pi](https://pi.dev) coding agent.

Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).

## Features

See `:help agentic-vs-tui` for a comparison to e.g. Claude TUI.

### Session & workflow

- Any number of sessions, each chat in any window of any tabpage
- Prompts queue during a usage limit and send when it lifts
- Attention bell/badge when chat is unfocused or no chat window follows
- Follow toggle (default: `<localLeader>a`)
- `:Agentic` shows the chat in the current window, and modifiers such as `:tab Agentic` or `:vert Agentic` place it
- Todos / code / files / diagnostics panels below the chat, in a configurable order (`windows.stack`)
- Changed-files panel (default: `<localLeader>f`) — one row per file the agent created or edited this session (see `:help agentic-file-activity`)
- External UI hook (`AgenticHeadersChanged` autocmd, see `:help AgenticHeadersChanged`) for plugins like [incline.nvim](https://github.com/b0o/incline.nvim)
- `:w[rite]` of your input prompt submits it (by default).
  - Opt-in register copy via `settings.send_register`.
  - Partial prompt submit (similar to Claude Code stash functionality.
    - `<CR><CR>` sends the current line (with count), `<CR>{motion}` sends the motion range, visual `<CR>` sends the selection.
  - Set new keymaps that put common custom prompts in the input. Comes with `<localLeader>c` for "Continue"
- Completion of any terms mentioned in chat
- Navigation keymap (default: `[[` and `]]`) for cursor jump between prompts.
- `:AgenticResume [{query}]` — the session picker, or the saved session the query matches (`session_id` prefix, else exact title, case-insensitive). Several matches open the picker on them. Resuming shows the chat and sends `session/load` to the agent. With `sessions.cd_on_load` (default `true`), nvim's working directory is changed to the session's recorded cwd.

### Rendering

- Bash-formatted shell commands (`shfmt` + treesitter injection)
- Grep/search output colouring — paths, line numbers, separators, match highlights
- Markdown tables aligned column-by-column
- Native vim folding for long tool output
- Sign-column block decorations
- Prose hard-wrapped at a fixed `wrap_width`, as it streams.

### Permissions

- Parse-tree shell command auto-approval — parses each `Bash`/`execute` command with the `zsh` treesitter grammar (required) and classifies every leaf independently, so pipelines, loops, conditionals, redirects, and env-prefixes are each checked rather than the whole string matched as one unit (a compound like `foo | bar && baz` is decomposed and matched per-segment). Two layers: a glob layer reading Claude's `Bash(...)` patterns from `settings.json`, and a structured option matcher reading the bundled `permissions.json` and `Config.permissions.structured` on tokenised flag identifiers, so option clustering (`sort -uo out`) and GNU abbreviation (`--out=x`) are matched where globs would not.
- While an execute prompt is shown, the parts of the command that are not known-safe are highlighted (`permissions.highlight_unapproved`)
- `/grant` — per-session paths under which file edits, shell redirects and `rm` auto-approve when recoverable (git-tracked and clean, or under a tmp root)
- Auto-approve tool calls by kind regardless of target path — read, search and skill by default, configurable (`permissions.auto_approve_kinds`)
- A per-session cache for "Allow always" / "Reject always" decisions, scoped per resource (file path, command, URL, …) so one approval never silently approves a different call of the same kind

## Requirements

- A recent Neovim and [pi](https://pi.dev) on PATH. For the Neovim version and
  the install command, see `:help agentic-requirements`.

### Treesitter parsers

Install the `bash` or `zsh` parser for shell command highlighting in chat. See `:help agentic-requirements-parsers`.

Code-fence and diff language labels are resolved through Neovim's registered
filetype↔parser mappings (`vim.treesitter.language.get_lang`). A filetype whose
parser name differs from it (`sh`→`bash`, `cs`→`c_sharp`) only labels correctly
once that mapping is registered. [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
registers these on parser install and is the recommended way to manage parsers.
Without it, register mappings yourself via `vim.treesitter.language.register`.

### Math rendering (optional)

If [`snacks.nvim`](https://github.com/folke/snacks.nvim)'s `image` module is installed and enabled, chat buffers attach to it automatically and LaTeX math (`$…$`, `$$…$$`) renders inline as images. Absent or disabled, it is a no-op. See snacks' `image` docs for its own requirements (graphics-capable terminal, ImageMagick, a LaTeX toolchain).

## Setup

The plugin works without a setup call. To change options, call `setup()` before the first session:

```lua
require("agentic").setup({
    -- ... any overrides
})
```

All options with defaults: [`lua/agentic/config_default.lua`](lua/agentic/config_default.lua).

## Documentation

Full reference: `:help agentic.txt`

## Licence

[MIT](LICENSE.txt)

Based on [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).
