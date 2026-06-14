---
paths: "lua/agentic/session_registry.lua,lua/agentic/session_manager.lua,lua/agentic/ui/chat_widget.lua,lua/agentic/ui/window_decoration.lua,lua/agentic/ui/message_writer.lua,lua/agentic/ui/permission_float.lua"
---

# Multi-tabpage architecture

One session instance per tabpage. `SessionRegistry` maps `tab_page_id -> SessionManager`.
One shared ACP provider subprocess, one ACP session ID per tabpage, full UI isolation.

- No module-level shared state for per-tabpage runtime data
- Namespaces are global, extmarks are buffer-scoped — module-level `nvim_create_namespace` is fine
- Highlight groups defined once globally in `lua/agentic/theme.lua`
- Keymaps and autocommands must be buffer-local
- See scoped storage: `vim.b`/`vim.bo`, `vim.w`/`vim.wo`, `vim.t`
