# Plan: no error reported only through `Logger.debug`
Status: reviewed — blocked on open questions 2 and 3 (items 1 and 7 wait on them); items 2-6, 8-9 ready

## Relevant files
- `notes/bug-silent-errors.md` (the report), `notes/audit-edge-cases.md` (4.1, 4.28)
- `~/.claude/rules/lang-lua.md` ("pcall requires visible error handling"; silent `pcall` only for cleanup of already-invalid state)
- `lua/agentic/utils/ansi.lua`, `lua/agentic/ui/chat_widget.lua`, `lua/agentic/ui/chat_buffer.lua`, `lua/agentic/utils/file_system.lua`, `lua/agentic/acp/acp_client.lua`, `lua/agentic/utils/grep_regex.lua`, `lua/agentic/ui/permission_manager.lua`, `lua/agentic/ui/tool_call_renderer.lua`, `lua/agentic/ui/message_writer.lua`, `lua/agentic/ui/floating_message.lua`, `lua/agentic/ui/status_indicator.lua`, `lua/agentic/utils/git_files.lua`, `lua/agentic/bootstrap.lua`, `lua/agentic/utils/buf_helpers.lua`, `lua/agentic/ui/subagent_transcript.lua`
- `notes/PLAN-failed-execute-body-offset.md`
- Tests: `lua/agentic/ui/permission_manager.test.lua`
- Skills: `rendering`, `permissions`

## Background
Each listed `pcall` was checked against the code. Two outcomes:
- **The call cannot fail on valid input** → the `pcall` goes. A failure is then a bug and raises. Where the raise lands decides what the user loses:
  - Chat-buffer writes run in `MessageWriter:_own_edit` → `BufHelpers.with_modifiable` (`buf_helpers.lua:21-35`): ERROR notify, and the rest of the edit callback is skipped.
  - Other session-update code reaches the subscriber `pcall` at `acp_client.lua:286-294` ("Subscriber callback error").
  - A `vim.schedule` callback or an autocmd shows a Neovim error message; the rest of that callback is skipped.
- **The call can genuinely fail** → the error is shown with `Logger.notify`.

Facts that decide the cases below (Neovim 0.12.6 runtime):
- `vim.treesitter.get_parser` returns `nil, err` when no parser can be made (`runtime/lua/vim/treesitter.lua:82-111`). It raises only for an invalid buffer.
- `vim.treesitter.start` raises when no parser can be made (`assert`, `treesitter.lua:460`). The `markdown` parser is bundled with Neovim (`lib/nvim/parser/markdown.so`), but see Open question 3 for the other ways `start` raises.
- `nvim_buf_set_lines` on a valid buffer with `modifiable` set does not fail outside textlock; on an unloaded buffer it loads it; it also succeeds from a `vim.schedule` callback while the cmdwin is open (tested headless).
- `nvim_buf_clear_namespace` raises only for an invalid buffer or a negative `line_start`; an end past the last line is accepted (tested headless).
- `nvim_buf_set_extmark` raises for a row or `end_col` out of range (tested headless).
- `nvim_buf_del_extmark` returns `false` for a missing id; it raises only for an invalid buffer.

## Changes

### Removed pcalls
1. **`ansi.lua:317-334`** — see Open question 2. The spans' columns match the lines written, but the start row is found by scanning the buffer for a `console` fence (`tool_call_renderer.lua:1565-1572`, `:1612-1618`; the second pattern `^`+console$` misses a `console-fold` fence and falls back to `start_row + 2`), and `PLAN-failed-execute-body-offset.md` finds a wrong offset reachable on deny-rule denials (merged body), harmful only with ANSI in that body. A raise from `MessageWriter:write_tool_call_block` (`message_writer.lua:2699`) is caught by `with_modifiable`, not the subscriber `pcall`; it ends the `_own_edit` callback before the block's range extmark and `self.tool_call_blocks[id]` are set (`:2737-2749`), so the block is orphaned: every later update warns "Tool call update for unknown block" (`:2805-2812`). Today the same fault only mis-highlights.
2. **`chat_widget.lua:351-367`** — call `nvim_buf_set_lines` directly inside the `BufHelpers.with_modifiable` callback. `with_modifiable` already checks validity and notifies on error (`buf_helpers.lua:14-36`).
3. **`file_system.lua:168-196`** — drop the `pcall` and its `Logger.debug` around the buffer reload in `write_file`. The buffer is checked valid at `:163`; `modifiable` is forced on. Same change at **`acp_client.lua:946-971`** (the `fs/write_text_file` reload, same code, not in the report; its comment at `:931` says so). Suggested: move the reload into one `FileSystem` helper that both sites call. A raise mid-reload leaves `modifiable` forced on, and in `write_file` it also skips `callback(nil)`. If audit 4.1 removes the `write_file` reload, the `file_system.lua` part of this item goes with it. A raise in `write_file` propagates out of `SessionManager:_persist_history` (`session_manager.lua:240`); at turn end (`:3762`) it skips `_sync_modified`, the transient retry and `_dispatch_deferred_prompts`. Accepted because the reload `set_lines` cannot fail on the valid, forced-modifiable buffer; decide 4.1 first so this edit is not made on code about to be deleted.
4. **`grep_regex.lua:547-554`** — drop the `pcall(vim.regex, …)` check in `translate`; keep `if not translation then return nil end`; delete the "A safety net" comment above it (`:546-547`). A pattern Vim rejects then reaches `regex_spans` (`tool_call_renderer.lua:498-502`), which already reports it as "Search highlight failed" (`:570-572`). Both `translate` callers (`tool_call_renderer.lua:1120`, `:1488`) feed only `extract_search_term_highlights`.
5. **`tool_call_renderer.lua:1976-1984`** (`clear_status_namespace`) and **`message_writer.lua:2995-3001`** — call `nvim_buf_clear_namespace` directly. The only caller of `clear_status_namespace` (`message_writer.lua:2986`) and the `:2995` call sit in the same callback after an unguarded `nvim_buf_get_lines` on the same buffer (`:2957-2958`), so the buffer is valid.
6. **`message_writer.lua:40`** — `local parser = vim.treesitter.get_parser(bufnr)`; keep `if parser`. Both callers (`:2758`, `:3120`) run after unguarded API calls on `bufnr`; a missing parser already gives `nil`, not an error.
7. **`pcall(vim.treesitter.start, …, "markdown")`** at **`chat_widget.lua:1377`**, **`:1442-1445`**, **`floating_message.lua:28`**, and the inner fallback at **`chat_buffer.lua:66`** (same call, not in the report) — see Open question 3.

### Notified errors
8. **`permission_manager.lua:1174-1189`** (`reject_and_cancel_remaining`) — keep both `pcall`s (one throwing callback must not leave the other requests unresolved; an unresolved request locks the session, `session_manager.lua:2265-2269`). Replace both `Logger.debug` calls with `Logger.notify(…, vim.log.levels.ERROR)`, worded as in `cancel_requests` (`:1107-1126`): "Permission callback error during reject: " / "Queued permission callback error during reject: ". The callback is `wrapped_callback` (`session_manager.lua:2214-2262`), which runs plugin code that can raise. Not new noise: `cancel_requests` already notifies the same failure.
9. **`permission_manager.lua:843-848`** (`add_request`, not in the report) — a request without `toolCall.toolCallId` logs `Logger.debug` and returns `false` without calling `callback`, so the request is never answered and the session locks (`session_manager.lua:2265-2269`). Replace with `Logger.notify(…, vim.log.levels.ERROR)` and call `callback(nil)` (answers "cancelled", as `cancel_requests` does) before `return false`.

### No change
10. **`status_indicator.lua`** — the report's `:285` does not exist (file has 102 lines); the `pcall` is at `:60-65` in `stop()`. It deletes an extmark that may be on a wiped buffer (`subagent_transcript.lua:166` calls `stop()` before its own validity check at `:167`): the cleanup case the rule allows.
11. **`git_files.lua:130-132`** — covered by `notes/PLAN-git-files-fail-open.md` (`diff_hunks` notifies and returns `nil`).
12. **`permission_manager.lua:651-656`** — see Open questions.

### Tests
- `permission_manager.test.lua`: `reject_and_cancel_remaining` with a current and a queued callback that both raise → both resolve and `Logger.notify` is called twice at ERROR.
- `permission_manager.test.lua`: `add_request` without `toolCallId` → `callback(nil)` and one ERROR notify.
- Run `make validate`.

## Expected outcome
- No `pcall` in the listed sites reports its error only through `Logger.debug`.
- A namespace clear on a bad buffer shows an error instead of a silent no-op; wrong ANSI rows and a markdown parser start failure per Open questions 2 and 3.
- A raising permission callback during reject-all shows an ERROR notification, as it already does during cancel.
- A permission request without a tool call id is answered "cancelled" with an ERROR notification instead of locking the session.

## Non-goals
- Whether to keep the `write_file` reload (audit 4.1).
- The failed-execute body offset (`PLAN-failed-execute-body-offset.md`).
- `_complete_request` (`permission_manager.lua:1093`) calls the callback without `pcall`; an error there already propagates.
- The silent `if disk_lines` skip in both reloads (read failure right after a successful write).
- The unused `filetype` option of `FloatingMessage.show`.

## Open questions
1. **Grant check file-read failure (`permission_manager.lua:651-656`).** Facts:
   - `_kind_args` reads the file whenever it exists, for every kind. `read_from_disk` fails for a directory (`file_system.lua:44-47`), so each grant check of a directory delete/move (and directory effects in `_check_command_effects`, `:606`) logs this today. Other failures: unreadable file (permissions).
   - `file_lines` matter only for `edit` on a tracked file with unstaged hunks: empty lines give no `edit_range`, so `safe_for_kind` refuses with "could not locate edit target range" (`grant_safety.lua:577-578`). The request then goes to the normal prompt (fails closed).
   - No grant refusal reason is shown to the user today: `_check_grant`'s reason is dropped at `permission_manager.lua:396`.

   Options: (a) skip the read for directories (`lstat` is already taken at `:641`) and `Logger.notify` WARN for the remaining failures — a new notification in the permission path; (b) leave it at `Logger.debug`, accepted as fail-closed; (c) show grant refusal reasons in general (separate feature, would cover this).
2. **ANSI extmark failure (`ansi.lua:317-334`, item 1).** A raise from the write path loses the tool call's tracker (item 1). Options: (a) keep the `pcall`, keep applying the other spans, and `Logger.notify` the first error once per `apply_highlights` call — visible, render completes (same reason as item 8 keeps its `pcall`s); (b) remove the `pcall` and move `Renderer.apply_block_highlights` in `write_tool_call_block` after the tracker is registered, so a raise costs only the highlights; (c) remove the `pcall` as is and accept the lost tracker. Recommended: (a).
3. **Markdown parser start failure (item 7).** `start(…, "markdown")` raises when:
   - the parser is missing or unloadable. The code treats this as a supported state: `bootstrap.lua:24-40` falls back and reports it only through `Logger.debug` (`:35-37`, the defect class of this plan).
   - a `markdown` highlights query on the rtp does not parse (tested: a bad `queries/markdown/highlights.scm` → "Query error … Invalid node type"). This is independent of the bootstrap check.
   - Also: a user parser at `~/.local/share/nvim/site/parser/markdown.so` exists here and shadows the bundled one, so "bundled" does not guarantee which parser loads.

   A raise leaves state half-built: at `chat_widget.lua:1442-1445` (`_create_buf_nrs`, called at `:1031`) `self.buf_nrs` is never set and the created buffers leak, so the widget is unusable; at `:1377` (also run from a `BufReadCmd` autocmd, `:1048-1053`) it comes before `nvim_buf_attach` and `LspServer.attach`, so the `on_bytes` tracker and completion LSP are skipped; at `chat_buffer.lua:66` it skips the snacks image attach, and in `SessionManager:_reload_chat` (`session_manager.lua:693`) it falls between `message_writer:reset()` and the replay, leaving an empty chat; at `floating_message.lua:28` it comes before `nvim_open_win`. `FloatingMessage.show`'s only callers (`acp_health.lua:119`, `clipboard.lua:21`) use the default `markdown` filetype.

   Options: (a) not supported — remove all these `pcall`s and the bootstrap fallback, so a missing parser fails at setup with one clear error (a query error still raises at each site); (b) supported, degraded — `bootstrap.lua` notifies WARN once, and the `start` sites stay guarded (a silent `pcall` whose cause was already notified; a query error stays silent); (c) remove the `pcall`s as drafted and accept the half-built state. Independent of these: bootstrap registers `AgenticChat` to `agentic` or `markdown` (`bootstrap.lua:31`, `:39`), so the `chat_buffer.lua:65-66` fallback could become one `vim.treesitter.start(bufnr)` call that infers the language from the filetype. The outer `pcall` at `chat_buffer.lua:65` stays under every option unless that change is made.
