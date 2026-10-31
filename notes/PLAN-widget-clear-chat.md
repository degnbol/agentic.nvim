# Plan: the widget clears only the chat buffer
Status: spec

## Relevant files
- `lua/agentic/ui/chat_widget.lua` — `ChatWidget:clear`
- `lua/agentic/session_manager.lua` — `clear_chat`
- `lua/agentic/ui/chat_widget.test.lua`, `lua/agentic/session_manager.test.lua`

## Background
`ChatWidget:clear` blanks every panel buffer except `input`, `code`, `files`
and `diagnostics`. `todos` and `activity` have owners that keep state and
redraw it (`TodoList:redraw`, `FileActivity:render`); only `agent` has no
owner object holding its text. Blanking an owned panel behind its owner
leaves the panel and the owner out of step until the next redraw (a
`BufReadCmd` reload of the todos panel brings the owner's entries back).

`SessionManager:clear_chat` is the only caller. Its caller
`_reset_conversation` clears `todo_list` right after, so no path shows the
mismatch today. The change makes each panel buffer written only by its owner.

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
- `chat_widget.test.lua`: rename the `clear()` cases to `clear_chat()`;
  replace "leaves the code, files and diagnostics panels" with one case
  asserting every buffer except `agent` keeps its lines.
- `session_manager.test.lua`: rename the `widget = { clear = ... }` mocks
  to `clear_chat` (the `_reset_conversation`, load and `switch_provider`
  fixtures; the `switch_provider` case asserts the widget is not cleared, so
  check it still asserts on the renamed spy).

## Expected outcome
- Each panel buffer other than the chat is written only by its owner.

## Non-goals
- `TodoList:clear` not calling its `on_change` (header count, panel close).

## Open questions
None.
