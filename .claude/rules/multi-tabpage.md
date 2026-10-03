---
paths: "lua/agentic/session_registry.lua,lua/agentic/session_manager.lua,lua/agentic/ui/chat_widget.lua,lua/agentic/ui/window_decoration.lua,lua/agentic/ui/message_writer.lua,lua/agentic/ui/permission_float.lua"
---

# Sessions, buffers and tabpages

Sessions are keyed by `SessionManager.id` in `SessionRegistry.by_id`. One
shared ACP provider subprocess, one ACP session ID per session, full UI
isolation.

- A tab binds to at most one session's widget, and a session to at most one
  tab. `SessionRegistry.tab_bindings` is the only holder of that link: resolve
  a session's tab with `SessionRegistry.tab_of(id)`, never store it.
- Every session buffer carries `vim.b.agentic_session_id`; resolve its owner
  with `SessionRegistry.owner_of_buf(bufnr)`.
- Buffer-local maps are closures over their owner and act on it wherever the
  buffer is shown — never on whichever session the current tab is bound to.
- No module-level shared state for per-session runtime data
- Namespaces are global, extmarks are buffer-scoped — module-level `nvim_create_namespace` is fine
- Highlight groups defined once globally in `lua/agentic/theme.lua`
- Keymaps and autocommands must be buffer-local, except where the trigger fires
  outside the session's buffers (`MessageWriter:_retry_folds_on_insert_leave`,
  `PermissionManager:_watch_layout`)
- See scoped storage: `vim.b`/`vim.bo`, `vim.w`/`vim.wo`, `vim.t`
