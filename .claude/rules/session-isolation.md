---
paths: "lua/agentic/init.lua,lua/agentic/bootstrap.lua,lua/agentic/session_registry.lua,lua/agentic/session_manager.lua,lua/agentic/ui/chat_widget.lua,lua/agentic/ui/window_decoration.lua,lua/agentic/ui/message_writer.lua,lua/agentic/ui/permission_float.lua"
---

# Session isolation

Sessions are keyed by `SessionManager.id` in `SessionRegistry.by_id`. One
shared ACP provider subprocess, one ACP session ID per session, full UI
isolation. A session is tied to no tabpage: its chat can show in any window
of any tab.

- Every session buffer carries `vim.b.agentic_session_id`; resolve its owner
  with `SessionRegistry.owner_of_buf(bufnr)`.
- Buffer-local maps are closures over their owner and act on it wherever the
  buffer is shown.
- Entry points that start outside an Agentic buffer (`Agentic.*`, `<Plug>`
  maps, commands) resolve their session with `SessionRegistry.current()`,
  `get_or_create()` when they may start one, or `create()` when they always
  start one.
- No module-level shared state for per-session runtime data
- Namespaces are global, extmarks are buffer-scoped — module-level `nvim_create_namespace` is fine
- Highlight groups defined once globally in `lua/agentic/theme.lua`
- Keymaps and autocommands must be buffer-local, except where buffer scoping
  misses the trigger (`MessageWriter:new`'s WinScrolled,
  `MessageWriter:_retry_folds_on_insert_leave`, `PermissionManager:_watch_layout`,
  the `BufEnter` in `bootstrap.lua` that records the last active session)
- See scoped storage: `vim.b`/`vim.bo`, `vim.w`/`vim.wo`. `vim.t` holds no
  per-session state.
