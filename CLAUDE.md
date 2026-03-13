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

When a tool call reaches terminal status ("completed"/"failed"), the block is
queued for **deferred freezing**. The actual freeze runs when the next content
write occurs (message chunk, new tool call), so the visual transition is hidden
by new content arriving. The freeze writes status text as static buffer content,
deletes old decoration + range extmarks, re-renders fresh decoration signs, and
removes the block from `MessageWriter.tool_call_blocks`. Subsequent updates are
silently ignored.

If a range extmark collapses (start >= end, indicating corruption),
`update_tool_call_block` bails out and removes the block from tracking rather
than proceeding with stale positions.

## ACP details

See @lua/agentic/acp/AGENTS.md for event pipeline, tool call lifecycle,
adapter override points, and permission flow.

## Testing

See @tests/AGENTS.md for test framework, file locations, and how to run tests.
