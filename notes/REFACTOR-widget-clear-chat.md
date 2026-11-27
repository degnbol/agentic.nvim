# Plan: the widget clears only the chat buffer
Status: reviewed spec
Priority: P3

## Relevant files
- `lua/agentic/ui/chat_widget.lua` — `ChatWidget:clear`
- `lua/agentic/session_manager.lua` — `clear_chat`
- `lua/agentic/ui/chat_widget.test.lua`, `lua/agentic/session_manager.test.lua`

## Background
`ChatWidget:clear` blanks every panel buffer except `input`, `code`, `files`
and `diagnostics`. The remaining panels `todos`, `activity` and `info` have
owners that keep state and redraw it (`TodoList:redraw`,
`FileActivity:render`, `SessionManager:render_info`); only `agent` has no
owner object holding its text. Blanking an owned panel behind its owner
leaves the panel and the owner out of step until the next redraw (a
`BufReadCmd` reload of the todos panel brings the owner's entries back).

`SessionManager:clear_chat` is the only caller. It has three callers, and
each clears or redraws the owned panels after it, so no path shows the
mismatch today:
- `_reset_conversation` clears `todo_list` and `file_activity`, then resets
  `_usage` and calls `render_info`.
- `_new_session_after_failed_load` clears `todo_list` and `file_activity`.
- `replace_with_history` is reached from `_new_session_after_failed_load` and
  from `restart_session` after `_cancel_session` (→ `_reset_conversation`).
  `_install_history` clears and reloads `file_activity`.

After the change the `info` panel keeps the owner's last snapshot on the
`_new_session_after_failed_load` path instead of going blank. The change makes
each panel buffer written only by its owner.

Origin: the "Restore here" branch of `do_restore` cleared by hand and left
`TodoList` full behind a blank panel. `1d6432e` deleted that branch.

## Changes

### `lua/agentic/ui/chat_widget.lua`
- `ChatWidget:clear` → `ChatWidget:clear_chat()`: blank the `agent` buffer
  only, keeping its `modified`. Drop the `kept` table and the loop. The
  docstring keeps the extmark/tracker paragraph and the `modified` paragraph.

### `lua/agentic/session_manager.lua`
- `clear_chat` calls `self.widget:clear_chat()`.

### Tests
- `chat_widget.test.lua` (`prompt navigation` block): change the four
  `widget:clear()` calls to `widget:clear_chat()`, including the two in the
  `reset() removes user-action markers` and `reset() removes region rails`
  cases. Replace both "clear() preserves the input buffer draft" and
  "clear() leaves the code, files and diagnostics panels" with one
  `clear_chat()` case: fill every buffer in `widget.buf_nrs` except `agent`
  (`_initialize` makes one per `Config.windows.stack` panel, so the loop
  covers `todos`, `activity` and `info` too), call `clear_chat()`, assert
  each kept its lines and `agent` is blank.
- `session_manager.test.lua`: rename the `widget = { clear = noop }` mocks
  to `clear_chat`: the `_cancel_session` case "resets is_generating and
  stops indicators on reset mid-turn", the `_reset_conversation`
  `make_session` fixture, and the `_do_load_acp_session` `make_load_session`
  fixture. In `switch_provider` "soft cancels old session without clearing
  widget/history", rename the `widget = { clear = widget_clear_spy }` key
  to `clear_chat` so its `called(0)` assertion still tests something.

## Expected outcome
- Each panel buffer other than the chat is written only by its owner.

## Non-goals
- `TodoList:clear` not calling its `on_change` (header count, panel close).

## Open questions
None.
