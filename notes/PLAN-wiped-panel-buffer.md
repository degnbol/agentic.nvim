# Plan: new buffer for a wiped panel
Status: reviewed spec

## Relevant files
- `lua/agentic/ui/chat_widget.lua` — `_initialize`, `_create_buf_nrs`,
  `_create_new_buf`, `setup_panel_buf`, `_bind_keymaps`, `_setup_queue`,
  `_attach_input`, `toggle_panel`, `input_win`, `sync_panels`, `clear`,
  `render_header`, `_stage_input`, `destroy`, the queue readers
  (`next_queued_block`, `queued_block_count`, `consume_queued_block`,
  `cancel_queue`)
- `lua/agentic/ui/widget_layout.lua` — `sync_panel`, `open_panel`
- `lua/agentic/ui/subagent_transcript.lua` — `new`: the stray-name step and
  the setup split this plan copies
- `lua/agentic/session_manager.lua` — `new` (the panel owners),
  `_setup_session_buf`, `_setup_buffer_lifecycle`, `_render_info` (named
  `render_info` on branch `shared-budget`), the
  `available_commands_update` branch, `_warn_unadvertised_command` (reads
  `States.getSlashCommands`), `_reset_conversation` (clears the commands)
- `lua/agentic/ui/context_list.lua`, `todo_list.lua`, `file_activity.lua` —
  the owners that capture a buffer number; `diagnostics_list.lua` reads the
  captured `__bufnr` in `__rows`
- `lua/agentic/session_recovery.lua` — `restore_refused_prompt`
- `notes/bug-bd-panel-loses-state.md` — the same panels after `:bd`
- Skills: `session-lifecycle`, `lua-class`; `.claude/rules/tests.md`

## Background
Only a wipe of the chat ends a session. A wipe of another panel buffer
(`:bwipeout <n>`, or a plugin that wipes hidden buffers) frees its number.
The session keeps the freed number in `widget.buf_nrs` and in every owner
that captured it, and each later use raises `Invalid buffer id`:
- `toggle_panel` on the info and activity panels raises, so they never open
  again: with a home window in `WidgetLayout.open_panel`, which reads the
  line count for the height outside its `pcall`; without one in
  `WindowDecoration.get_header`.
- Content panels (todos, code, files, diagnostics) open when their buffer
  has rows (`sync_panels`, which raises on the old number).
  `ContextList:render` and `FileActivity:render` skip the write
  (`BufHelpers.with_modifiable` returns false for an invalid buffer), so
  `on_change` never runs and the panel never opens again. `TodoList:render`
  raises on `nvim_buf_clear_namespace` after the write.
- `InfoPanel.render` raises on `nvim_buf_clear_namespace`. On branch
  `shared-budget`, `AgenticBudgetChanged` renders every session's info, so
  the error stops the loop and reaches another session's handler or the
  budget tick.
- The input: the `BufWinLeave` check on the chat reads its `modified`, and
  the queue readers read its extmarks; both raise. The permission keymaps
  already skip it (`PermissionManager:_shadow_keymap`), and `_sync_keymaps`
  runs again on `BufWinEnter`, so a new input gets them when it shows.
  `States` reads and writes on it are `pcall`-guarded and do not raise.

A wipe is not undone at once: a `BufWipeout` handler that makes the buffer
again would fight the user. A panel gets a new buffer when the session next
**writes to or shows** it. The toggled panels (info, activity, input) are
shown by a key; the content panels are shown by a write, which has no key
to wait for. A buffer made for a write stays hidden and unlisted until its
panel opens. Code that only reads (queue counts, `modified`, header
context, the advertised commands) treats a wiped buffer as absent and does
not make one.

Every owner reaches its buffer through one widget accessor instead of a
captured number, so one place knows the current number and nothing needs
rebinding. After `destroy` the accessor gives nil, and owners skip: late
callbacks (the git probe of `FileActivity:reconcile`, the budget event)
would otherwise make buffers for a dead session.

The setup of a panel buffer splits as `SubagentTranscript:new` already
splits it:
- once per buffer: create it and register its buffer-local autocmds;
- per load: options, b-vars and keymaps, which `:bd` resets
  (`bug-bd-panel-loses-state.md`). The `:bd` fix calls only these from
  `BufReadCmd`; calling the once-per-buffer part there would stack
  autocmds.

## Changes

### `lua/agentic/ui/chat_widget.lua`
- `--- @field on_panel_buf? fun(panel: agentic.ui.ChatWidget.StackPanel, bufnr: integer)`:
  runs after `panel_buf` makes a buffer that replaces a wiped one, once the
  number is in `buf_nrs`.
- `_create_new_buf`: before the rename, deletes a buffer that already holds
  the name, as `SubagentTranscript:new` does (`:e agentic://…` or a tag jump
  after a wipe leaves one; the rename raises E95 on it).
- `ChatWidget:_create_panel_buf(panel: agentic.ui.ChatWidget.StackPanel): integer`
  (once per buffer): `_create_new_buf(panel, false)`, stores the number in
  `self.buf_nrs[panel]`, then the markdown parser where `_create_buf_nrs`
  starts one, the widget keymaps (`_bind_buf_keymaps`), and for `input` the setup now in `_initialize`
  (`_setup_queue`, `_attach_input`, the `TextChanged` and `BufReadCmd`
  autocmds), which reads `buf_nrs.input`. Renders nothing.
- `_create_buf_nrs` → `ChatWidget:_create_bufs()` with no return value:
  `_initialize` first sets `self.buf_nrs = { agent = <chat> }`, then
  `_create_bufs` fills the other panels in place through
  `_create_panel_buf`. In-place updates keep `PermissionManager._buf_nrs`
  (the same table) current. `_bind_keymaps` binds only the chat.
- `ChatWidget:panel_buf(panel: agentic.ui.ChatWidget.StackPanel): integer|nil`:
  nil after `destroy`; the panel's buffer while it is valid; else
  `_create_panel_buf`, then `on_panel_buf`.
- Through `panel_buf`: `toggle_panel` (on the open path only, after
  `_home_in_tab` found a home), `input_win`, `_stage_input`.
- Wiped buffer skipped: `sync_panels` (no panel to sync; a write makes it),
  `clear`, `render_header`. The queue readers treat a wiped input as an
  empty queue.

### `lua/agentic/session_manager.lua`
- `SessionManager:_setup_panel_buf(panel: agentic.ui.ChatWidget.StackPanel, bufnr: integer)`
  (per load): `_setup_session_buf(bufnr, nil)`; `bind_keymaps(bufnr)` of the
  panel's owner (`d` of code, files, diagnostics; `<CR>` and `Q` of
  activity); for `input`, `States.setChatBufnr`, and
  `SlashCommands.setCommands(bufnr, self._available_commands)` when that
  field is set. Uses `bufnr`, never `panel_buf`. Renders nothing.
- `SessionManager:_watch_panel_buf(panel: agentic.ui.ChatWidget.StackPanel, bufnr: integer)`
  (once per buffer): the panel's `BufReadCmd` re-render, from
  `_setup_buffer_lifecycle`'s `reloads`, now keyed by panel.
  `_setup_buffer_lifecycle` keeps only the chat's autocmds.
- `new`: builds the owners, then for each panel buffer calls
  `_watch_panel_buf` and `_setup_panel_buf`, then sets
  `widget.on_panel_buf` to call both. This replaces the
  `_setup_session_buf` loop and the `States.setChatBufnr` call. No owner
  writes before this point.
- The owners get `function() return self.widget:panel_buf("<panel>") end`.
- `--- @field _available_commands? agentic.acp.AvailableCommand[]`: nil until
  the first `available_commands_update`. That update and
  `_reset_conversation` set it and call `SlashCommands.setCommands` on
  `buf_nrs.input` (a wiped input gets the field from `_setup_panel_buf`).
  `_warn_unadvertised_command` keeps reading `buf_nrs.input`.
- `_render_info`: skips when `panel_buf("info")` is nil.
- The chat's `BufWinLeave` check: a wiped input has no draft.

### Panel owners
- `ContextList.new(self, get_bufnr: fun(): integer|nil, on_change)`; the `d`
  keymaps move to `ContextList:bind_keymaps(bufnr: integer)`. `__bufnr`
  becomes `__get_bufnr`, also in `DiagnosticsList:__rows`.
- `TodoList:new(get_bufnr: fun(): integer|nil, on_change, on_close)`,
  `FileActivity:new(get_bufnr: fun(): integer|nil, on_change)`: `_bufnr`
  becomes `_get_bufnr`, called at each use. `FileActivity:_setup_keybindings`
  becomes `FileActivity:bind_keymaps(bufnr: integer)`.
- Each render skips when the getter gives nil.

### Other callers
- `Recovery.restore_refused_prompt`: `sm.widget:panel_buf("input")`.

### Tests
- `chat_widget.test.lua`: `panel_buf` returns the same buffer while it is
  valid; after a wipe it returns a new one with the panel's options, b-vars
  and widget keymaps, calls `on_panel_buf` once, and updates `buf_nrs` in
  place; after `destroy` it returns nil and makes no buffer; a stray buffer
  holding the panel's name is replaced.
- `tests/integration/test_buffer_lifecycle.lua`, two sessions:
  - wipe the info buffer of one: rendering the info raises nothing;
    `<localLeader>I` opens the panel with its content.
  - wipe the files buffer: adding a file opens the panel with the file, and
    `d` removes it.
  - wipe the input buffer: the chat's `BufWinLeave` and a queue drain raise
    nothing; `input_win` gives an input with the send keymaps, completion
    and the advertised slash commands.
  - the other session's panel buffers are unchanged.
- Owner tests (`context_list`, `todo_list`, `file_activity`): construct with
  a getter; a nil getter skips the render.

## Expected outcome
After a panel buffer is wiped, the session goes on without errors. The
panel gets a new buffer, with its content, options and keymaps, when the
session next writes to it or the user opens it. The info panel is written
on many events (and each minute with `shared-budget`), so its buffer
usually comes back without a key.

## Non-goals
- `:bd` on a panel (`bug-bd-panel-loses-state.md`); it can call the
  per-load functions (`setup_panel_buf`, `_bind_buf_keymaps`,
  `_setup_panel_buf`).
- Keeping the draft or queued blocks of a wiped input.
- Subagent transcript and message buffers.

## Open questions
None.
