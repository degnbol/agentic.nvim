# Bug: errors reported only through `Logger.debug`

`Logger.debug` is off by default, so these failures are invisible. Found by a read-only audit (2026-10-26). Each site needs a decision: surface the error (`Logger.notify`), or remove the `pcall` when the call cannot fail.

| Site | What is swallowed |
|---|---|
| `lua/agentic/utils/ansi.lua:317-334` | extmark failures in `apply_highlights` |
| `lua/agentic/ui/chat_widget.lua:351-367` | `nvim_buf_set_lines` in `ChatWidget:clear`; a nested `pcall` inside `BufHelpers.with_modifiable`, which already notifies |
| `lua/agentic/utils/file_system.lua:161-196` | buffer reload after `write_file` (the reload itself is audit candidate 4.1) |
| `lua/agentic/utils/grep_regex.lua:547-554` | `pcall(vim.regex)`; the caller `regex_spans` already reports the same failure |
| `lua/agentic/ui/permission_manager.lua:651-656` | file read failure while checking a grant (fails closed, reason not shown) |
| `lua/agentic/ui/permission_manager.lua:1174-1189` | callback errors in `reject_and_cancel_remaining`; `cancel_requests` (:1107-1126) notifies, `_complete_request` (:1093) has no `pcall` |
| `lua/agentic/utils/git_files.lua:130-132` | `git diff` failure (see `bug-git-files-fail-open.md`) |
| `lua/agentic/ui/tool_call_renderer.lua:1977`, `message_writer.lua:40`, `:2995`, `status_indicator.lua:285` | `pcall`s on calls that only fail on an invalid buffer |
| `lua/agentic/ui/chat_widget.lua:1377, 1442-1445`, `floating_message.lua:28` | `pcall(vim.treesitter.start)` |

Rule: `~/.claude/rules/lang-lua.md` ("pcall requires visible error handling").
