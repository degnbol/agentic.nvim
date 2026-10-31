# Bug: a wiped panel buffer breaks its panel for the rest of the session
Status: draft

## Relevant files
- `lua/agentic/ui/chat_widget.lua` — `_create_buf_nrs`, `_create_new_buf`,
  `setup_panel_buf`, `toggle_panel`, `_setup_queue`, `_attach_input`
- `lua/agentic/ui/widget_layout.lua` — `open_panel`, `resize_panel`
- `lua/agentic/session_manager.lua` — `new` (the panel owners),
  `_setup_session_buf`, `_setup_buffer_lifecycle`, `render_info`
- `lua/agentic/bootstrap.lua` — the `User AgenticBudgetChanged` autocmd
  (branch `shared-budget`)
- [`bug-bd-panel-loses-state.md`](bug-bd-panel-loses-state.md) — the same
  panels after `:bd`, which keeps the buffer number

## Background
Only a wipe of the chat ends a session. A wipe of any other panel buffer
(`:bwipeout <n>`, or a plugin that wipes hidden buffers) frees its number,
and the session goes on with the freed number in `widget.buf_nrs` and in
every object that captured it. Each later use raises `Invalid buffer id`:
- `toggle_panel` reads the header of `buf_nrs[panel]`, then
  `WidgetLayout.open_panel` shows it, so the panel never opens again.
- Each write to the panel raises in the writer's caller.

Holders of a panel's buffer number, captured when the session starts:
- todos: `TodoList`
- code: `CodeSelection`
- files: `FileList`
- diagnostics: `DiagnosticsList`
- activity: `FileActivity`
- info: none; `render_info` reads `widget.buf_nrs.info` on each call
- input: `States.setChatBufnr`, the completion LSP and the `on_bytes`
  tracker (`_attach_input`), `_send_widgets` (`_setup_queue`), its
  `BufReadCmd` and the send keymaps
- every panel: the session keymaps (`_setup_session_buf`), the `BufReadCmd`
  redraw in `_setup_buffer_lifecycle`, and the `BufWinEnter` header
  autocmd (`_create_new_buf`)

On branch `shared-budget`, `AgenticBudgetChanged` calls `render_info` on
every session. A session with a wiped info buffer raises there: the loop
stops before the other sessions' panels, and the error reaches whichever
caller fired the event (another session's `usage_update` handler, or the
budget's minute tick).

## Changes
A panel whose buffer is gone gets a new buffer when it is next opened, not
when the old one is wiped, so a wipe is not undone behind the user's back.
- `ChatWidget` makes the panel's buffer again: `_create_new_buf`, its
  options and b-vars, and the panel-specific setup (`_setup_queue` and
  `_attach_input` for input).
- Each holder above takes the new buffer number and redraws into it from
  its state; the session sets up its keymaps and `BufReadCmd` on it.
- Until the panel is opened again, writes to it are skipped, so a wiped
  panel raises nowhere (the `AgenticBudgetChanged` loop included).

## Expected outcome
After a panel buffer is wiped, its session goes on without errors, and
opening the panel shows it again with its current content.
