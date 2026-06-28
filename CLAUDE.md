# agentic.nvim

Neovim plugin providing AI chat interface via ACP (Agent Client Protocol).
Fork of [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim).

- Neovim v0.11.0+, LuaJIT 2.1 (Lua 5.1)
- `goto`/`::label::` forbidden (Selene parser limitation)
- Never use `vim.notify` directly — use `Logger.notify`
- Logger has only `debug()`, `debug_to_file()`, and `notify()` — no warn/error/info

## You are running through this plugin

When working in this repo, you are hosted by agentic.nvim itself via ACP
(Agent Client Protocol). The provider is configured in `Config.provider` —
not necessarily Claude. Anything that depends on the host (slash command
interception, permission flow, `environment_info`, what's forwarded in
`available_commands_update`) follows the ACP path, not the TUI path.
Provider-specific behaviour (e.g. which tools the SDK auto-approves vs
escalates) is adapter-dependent — see the `provider-system` project
skill.

## Debugging at runtime

`Logger.debug()` (prints to `:messages`) is gated by `Config.debug`.
`Logger.debug_to_file()` (appends to `~/.cache/nvim/agentic_debug.log`) is
gated by `Config.log`. Both default to `false` and are independent — enable
`log` alone for file logging without screen distraction. For temporary
diagnostics that must fire unconditionally, use `io.open` directly:

```lua
do
    local f = io.open("/tmp/agentic_diag.log", "a")
    if f then
        f:write(string.format("%s %s\n", os.date("%H:%M:%S"), msg))
        f:close()
    end
end
```

Remove before committing. Never leave `io.open` debug logging in production code.

## Multi-tabpage architecture

Multi-tabpage isolation rules (no module-level shared state, buffer-local keymaps,
`vim.b`/`vim.t` scoping, namespace lifecycle) live in `.claude/rules/multi-tabpage.md`.
That rule auto-loads when session/widget/registry files are accessed.

## Validation

```bash
make validate
```

Outputs 5-6 lines (exit codes + log paths).
On failure, read the log file with `tail` or `rg`, never the Read tool.

Log paths: `.local/agentic_{luals,selene,helptags,test}_output.log`

## Key files

- `lua/agentic/config_default.lua` — all user-configurable options
- `lua/agentic/theme.lua` — highlight groups (update README.md when adding new ones)
- `lua/agentic/acp/adapters/` — provider-specific adapters

## Session cache location

Persisted chat sessions: `~/.cache/nvim/agentic/sessions/<normalized-cwd>_<hash>/<session-id>.json`.
Grep by `"title":"<name>"` to find a session renamed via `/rename` across all projects.

## Chat-buffer rendering and folding

Tool call blocks, code-fence widths and info-strings, search highlighting, and
body folding — see the `rendering` project skill. Per-site rationale (sign
extmarks, status footer writes, fold-anchor scheduling, priority numbers) lives
in docstrings at the relevant functions in `tool_call_renderer.lua`,
`message_writer.lua`, `extmark_block.lua`, `theme.lua`, and the
`queries/agentic/*.scm` files. The chat buffer always has folds; any viewport,
scroll, or cursor math must be fold-aware (see neovim skill § "Common
arithmetic pitfall").

## Session lifecycle, cross-turn state, and header pipeline

Three closely related areas — all covered by the `session-lifecycle` project skill.
Load that skill before editing `session_manager.lua`, `chat_history.lua`, or
`window_decoration.lua`. It documents: the three ACP session/load race conditions
and their `_restoring`/`_session_epoch`/`_destroyed` guards; the MessageWriter
cross-turn flag hazards (which flags exist, where each resets); and the header
state pipeline (`SessionManager` → `WindowDecoration.set_headers_state()` →
`vim.t[tab].agentic_headers` → `AgenticHeadersChanged` autocmd → external plugins).

## Auto-scroll and attention notifications

See the `autoscroll` project skill for the two-mechanism model
(manual-scroll pause + prose pin), the per-instance state on
`MessageWriter`, the chunk flow, and badge clearing rules. The discipline
rule worth holding in your head: any new method that grows the chat
buffer must call `_auto_scroll(bufnr)` *before* the write. User-facing
behaviour summary is in `doc/agentic.txt § Auto-scroll`.

## Input buffer completion

Completion for `/` and `@` uses an in-process LSP server (`lua/agentic/completion/lsp_server.lua`).
Design rationale (why LSP over completefunc, why `@` directory walk is reimplemented,
multi-tabpage client reuse) is documented in that file's module and function docstrings.
Syntax highlighting for `/command` and `@path` uses `syntax/AgenticInput.vim` and
`syntax/AgenticChat.vim`; the line-start-only slash highlight rationale is in a comment
in `AgenticChat.vim`.

## Keymaps and configuration

All user-configurable options live in `config_default.lua`. Keymaps are grouped
by scope: `keymaps.widget` (all Agentic buffers), `keymaps.prompt` (input
buffer only), `keymaps.chat` (chat buffer only), `keymaps.diff_preview`.

Keymap values use `BufHelpers.multi_keymap_set` which accepts a string, a list
of strings, or a list of `{ key, mode = ... }` tables for multi-mode bindings.
All widget keymaps are applied as buffer-local maps in `ChatWidget:_setup_keymaps`
over every buffer in `self.buf_nrs`.

## Client-side auto-approval

See the `permissions` project skill for the two-tier model
(SDK-internal + ACP-bridge), the four auto-approval mechanisms
(read-only tools, compound Bash matching, allow/reject-always cache,
`/trust` scope) and the six safety properties layered on top of trust
scope. Implementation lives in `PermissionManager`, `PermissionRules`,
`TrustSafety`, `GitFiles`, and `PermissionFloat`.

## ACP details

Event pipeline, session-update routing, tool-call lifecycle, adapter
override points, execute rendering, and known ACP limitations live in
the `provider-system` project skill. Load it before any work in
`lua/agentic/acp/`. The global `acp` skill covers the ACP protocol
spec itself, not our implementation.

### Upstream issues (claude-agent-sdk)

- **anthropics/claude-code#35298** — Skills with `paths` triggers crashed
  Read/Write/Edit for files outside cwd. Fixed in SDK 0.2.104 / claude-agent-acp
  0.27.0. See @.claude/skills/acp/references/claude-agent.md

## Testing

Test framework, file locations, and how to run tests are in
`.claude/rules/tests.md` (auto-loaded when `**/*.test.lua` or `tests/**` is
accessed).
