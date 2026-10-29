# Plan: a conflicting restore resets the session like a restart
Status: spec

## Background
The conflicting branch of `do_restore` (`lua/agentic/session_restore.lua`,
provider without session load, "Restore here") clears the outgoing session
by hand: `agent:cancel_session`, `clear_chat`, the three context lists and
`permission_manager:clear()`. That is a subset of
`SessionManager:_cancel_session` → `_reset_conversation`, and it has drifted.
`restore_from_history` → `new_session({ restore_mode = true })` skips
`_cancel_session`, so on this path nothing resets:
- `todo_list`: the panel is blanked by `ChatWidget:clear` while `TodoList`
  keeps its entries; a reload of the panel (`BufReadCmd` → `redraw`) brings
  the old session's todos back.
- `is_generating` and the status indicator, `session_id`, the retry timer and
  `_transient_attempt`, `_hook_records`, `_title_user_set` and the chat title
  (an untitled restore keeps the old title), `_usage`, slash commands,
  `config_options`, the budget and the load gate.

`SessionManager:restart_session` already does the same transition correctly:
`_cancel_session()`, then `restore_from_history(saved_history)`.

Separately, `ChatWidget:clear` blanks every panel buffer except `input`,
`code`, `files` and `diagnostics`. `todos` and `activity` have owners that
keep state and redraw it (`TodoList:redraw`, `FileActivity:render`); only
`agent` has no owner object holding its text. Blanking an owned panel
behind its owner is what made the todos leak visible as a blank panel.
`switch_provider` and `Recovery.respawn_preserving_history` clear
`todo_list` themselves and keep the chat on purpose; they do not call
`ChatWidget:clear` and are unaffected.

## Changes

### `lua/agentic/session_manager.lua`
- Rename `_cancel_session` → `cancel_session` (now called from
  `session_restore.lua`); update its five callers.
- `restore_from_history`: the comment above `self.file_activity:clear()`
  justifies it by "this path can arrive from `SessionRestore` with a live
  tally". After the change every caller has reset first; the clear stays for
  `_fallback_restore_from_local`, where `FileActivity:load` keeps ops recorded
  before it ran. Reword the comment to that reason.
- `clear_chat` calls `self.widget:clear_chat()`.

### `lua/agentic/session_restore.lua`
- Conflicting branch: replace `agent:cancel_session`, `clear_chat`, the three
  list clears and `permission_manager:clear()` with `session:cancel_session()`.

### `lua/agentic/ui/chat_widget.lua`
- `ChatWidget:clear` → `ChatWidget:clear_chat()`: blank the `agent` buffer
  only, keeping its `modified`. Drop the `kept` table and the loop. The
  docstring keeps the extmark/tracker paragraph and the `modified` paragraph.

### Tests
- `session_restore.test.lua`: the mock session gets `cancel_session`; drop
  the `agent.cancel_session`, `clear_chat`, `permission_manager` and three
  list mocks the branch no longer calls. Assert `cancel_session` is called
  once on "Restore here", zero times on dismiss / no conflict.
- `chat_widget.test.lua`: rename the `clear()` cases to `clear_chat()`;
  replace "leaves the code, files and diagnostics panels" with one case
  asserting every buffer except `agent` keeps its lines.
- `session_manager.test.lua`: rename `_cancel_session` references and the
  `widget = { clear = ... }` mocks to `clear_chat` (the `_reset_conversation`,
  load and `switch_provider` fixtures; the `switch_provider` case asserts the
  widget is not cleared, so check it still asserts on the renamed spy).

## Expected outcome
- "Restore here" over a conflicting session, with a provider that cannot
  load sessions, resets the session as `/restart` does: todos, title, running
  turn, config options, hook records and the rest no longer carry over.
- Each panel buffer other than the chat is written only by its owner.

## Non-goals
- `TodoList:clear` not calling its `on_change` (header count, panel close).

## Open questions
None.
