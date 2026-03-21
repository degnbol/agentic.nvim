# agentic.nvim

Neovim plugin providing AI chat interface via ACP (Agent Client Protocol).
Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).

- Neovim v0.11.0+, LuaJIT 2.1 (Lua 5.1)
- `goto`/`::label::` forbidden (Selene parser limitation)
- Never use `vim.notify` directly — use `Logger.notify`
- Logger has only `debug()`, `debug_to_file()`, and `notify()` — no warn/error/info

## Multi-tabpage architecture

One session instance per tabpage. `SessionRegistry` maps `tab_page_id -> SessionManager`.
One shared ACP provider subprocess, one ACP session ID per tabpage, full UI isolation.

- No module-level shared state for per-tabpage runtime data
- Namespaces are global, extmarks are buffer-scoped — module-level `nvim_create_namespace` is fine
- Highlight groups defined once globally in `lua/agentic/theme.lua`
- Keymaps and autocommands must be buffer-local
- See scoped storage: `vim.b`/`vim.bo`, `vim.w`/`vim.wo`, `vim.t`

## Validation

Run after ANY Lua file changes:

```bash
make validate
```

Outputs 5-6 lines (exit codes + log paths). Never redirect its output.
On failure, read the log file with `tail` or `rg`, never the Read tool.

Log paths: `.local/agentic_{format,luals,selene,test}_output.log`

## Key files

- `lua/agentic/config_default.lua` — all user-configurable options
- `lua/agentic/theme.lua` — highlight groups (update README.md when adding new ones)
- `lua/agentic/acp/adapters/` — provider-specific adapters

## Tool call block rendering

Border decorations (╭─ │ ╰─) use `sign_text` extmarks in the sign column, not
inline virtual text. This is more stable during buffer edits — signs survive
line content replacement without delete/recreate cycles.

Status text (" ✔ completed ", " ✖ failed ", etc.) is written directly into the
footer buffer line as real text using `nvim_buf_set_text` (not `set_lines` —
that shifts extmarks on the replaced line), then highlighted with an extmark
(`NS_STATUS` namespace). This avoids the entire class of overlay-to-static-text
timing bugs. Status changes just replace the footer line content in place. No
deferred freezing, no cleanup passes.

**All programmatic highlighting uses extmarks**, not vim syntax rules. Extmarks
work regardless of `vim.bo.syntax` state — whether treesitter has disabled it
(default after `vim.treesitter.start()`) or a user/plugin re-enables it with
`vim.bo.syntax = 'ON'`. This makes the highlighting robust against user
configuration. Highlight group definitions are set in `theme.lua` via
`nvim_set_hl`, which works independently of vim syntax state. The
`AgenticDimmedBlock` group (dims ` ```markdown ` fences only) is defined in
`ftplugin/AgenticChat.lua` via a targeted treesitter query override.

Content comparison in `update_tool_call_block` excludes the footer line (which
has status text in the buffer but `""` in `_prepare_block_lines` output), so
status-only updates skip the expensive content replacement path.

If a range extmark collapses (start >= end, indicating corruption),
`update_tool_call_block` bails out and removes the block from tracking rather
than proceeding with stale positions.

## Search tool call rendering

Search/grep results use two separate code fences in `_prepare_block_lines`:

1. **Command** — ` ```bash ` fence around the search command (argument)
2. **Results body** — ` ```console ` fence around result lines

The body always gets a `console` fence (prevents markdown parsing of `--`,
`*`, etc.). Fold markers (`{{{`/`}}}`) go inside the console fence when line
count exceeds `search_max_lines` (default 8). Never double-wrap — the body
from the adapter is raw text lines (no fences), so the console fence is the
only one.

Match highlighting: ANSI codes from the provider (preferred, rarely available)
or regex fallback that extracts the pattern from the command string and
re-matches against body lines. Highlights use `AgenticSearchMatch` extmark
with priority 200.

## Tool call body folding

Long tool call output uses vim-native folds (`foldmethod=marker`) instead of
truncation. Fold markers (`{{{`/`}}}`) are embedded in the buffer content and
concealed via extmarks (treesitter is active, so vim syntax `conceal` doesn't
work). The chat buffer sets `foldlevel=0` so folds start closed.

Folding thresholds are configured per tool kind:
- `search_max_lines` — search/grep tool output
- `execute_max_lines` — shell command stdout
- `fetch`/`WebSearch` — always folded (informational, rarely needed by users)

`lua/agentic/ui/foldtext.lua` provides a custom `foldtext` showing line count.
Users toggle with standard fold commands (`zo`/`zc`/`za`).

## Input buffer completion

Completion for `/` slash commands and `@` file references uses an in-process LSP
server (`lua/agentic/completion/lsp_server.lua`), not custom completefunc/omnifunc.
The LSP declares `/` and `@` as trigger characters so any LSP-aware completion
framework (blink.cmp, nvim-cmp, built-in) picks them up automatically. No
plugin-specific keymaps needed.

- `vim.lsp.start()` with same `name` + `root_dir` reuses one client across
  buffers (handles multi-tabpage)
- Handler uses `nvim_get_current_buf()` not URI (all input buffers share name
  `agentic://prompt`)
- `States.getSlashCommandsForBuffer(bufnr)` reads from specific buffer (not
  `vim.b[0]` which is unreliable in LSP handler context)
- `FilePicker.get_files(bufnr)` provides cached file list; `SessionManager`
  holds a strong reference to prevent GC of the weak-tabled FilePicker instance

### Input buffer syntax highlighting

Slash commands (`/command`) and `@` mentions (`@path`) get vim syntax highlighting
via `syntax/AgenticInput.vim`, sourced by a deferred `vim.bo.syntax = "ON"` in
`ftplugin/AgenticInput.lua` (needed because `vim.treesitter.start()` clears syntax
after the ftplugin runs).

The prefix character (`/`, `@`) and the body text are separate syntax groups using
`nextgroup` + `contained` — no character belongs to two groups, preventing
unintended style bleed (e.g. underline from the path group leaking onto `@`).
Prefix groups (`AgenticSlashCommandPrefix`, `AgenticMentionPrefix`) link to
`@punctuation.special`; body groups keep their existing links (`@function.call`,
`@string.special.path`).

**Slash commands are highlighted only at line start** (`^/`), not mid-line. Completions
trigger in both positions, but only line-start invocations have call semantics — a `/`
mid-line is discussion or documentation, not an invocation. The highlight
(`AgenticSlashCommand` → `@function.call`) signals "this will execute" vs plain text.

## Keymaps and configuration

All user-configurable options live in `config_default.lua`. Keymaps are grouped
by scope: `keymaps.widget` (all Agentic buffers), `keymaps.prompt` (input
buffer only), `keymaps.chat` (chat buffer only), `keymaps.diff_preview`.

Keymap values use `BufHelpers.multi_keymap_set` which accepts a string, a list
of strings, or a list of `{ key, mode = ... }` tables for multi-mode bindings.
All widget keymaps are applied as buffer-local maps in `ChatWidget:_setup_keymaps`
over every buffer in `self.buf_nrs` (chat, input, todos, code, files, diagnostics).

The plugin's `ftplugin/` directory holds filetype-specific setup (e.g.
`AgenticChat.lua` for treesitter query overrides). Buffer filetypes are set in
`ChatWidget:_create_buf_nrs`: `AgenticChat`, `AgenticInput`, `AgenticTodos`,
`AgenticCode`, `AgenticFiles`, `AgenticDiagnostics`.

## ACP details

See @lua/agentic/acp/AGENTS.md for event pipeline, tool call lifecycle,
adapter override points, and permission flow.

## Testing

See @tests/AGENTS.md for test framework, file locations, and how to run tests.
