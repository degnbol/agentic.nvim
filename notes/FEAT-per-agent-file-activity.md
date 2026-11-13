# Plan: one file activity tally per agent
Status: draft
Priority: P3
Depends: REFACTOR-subagent-shared-keys.md

## Relevant files
- `lua/agentic/ui/file_activity.lua` — `FileActivity:new(get_bufnr,
  on_change)`, `serialize`, `load`, `clear`, `bind_keymaps`
- `lua/agentic/session_manager.lua` — `self.file_activity` (created next to
  the widget's `activity` buffer), `_record_file_op`, `_record_shell_ops`,
  `_view_for`, `toggle_file_activity`, `_install_history`,
  `_sync_history_context` (the `history.file_activity` refresh), `clear()`
  sites
- `lua/agentic/subagents.lua` — `Subagents.Agent`, `transcript`,
  `owner_of`, `_open_agent` and `add_history_transcripts` (the two places an
  `Agent` record is made), `_new_transcript`'s `on_wipeout`, `reset`,
  `_bind_agent_keymaps`, `_open_input`, `_agent_input_win`
- `lua/agentic/ui/subagent_transcript.lua`, `ui/subagent_input.lua`
- `lua/agentic/ui/chat_widget.lua` — `toggle_panel`, `_home_in_tab`,
  `home_win`, `_adopt_home`, `_track_home`, the QuitPre close,
  `PANEL_RELOADS`, `_watch_panel_buf`, `panel_buf`, `on_panel_buf`,
  `_bind_buf_keymaps` (`agent.to_input`), `_create_new_buf`
- `lua/agentic/ui/widget_layout.lua` — `open_panel`, `split_target`,
  `panel_win`, `resize_panel`, `close_panel` (all over `win_nrs`/`buf_nrs`,
  one slot per panel name)
- `lua/agentic/ui/chat_history.lua` — `ChatHistory.Subagent`,
  `set_subagent_task` (replaces the whole record)
- `doc/agentic.txt` § `agentic-file-activity`, § `agentic-subagents`
- `.claude/rules/session-isolation.md`, `.claude/rules/help.md`
- Skills: `session-lifecycle` (load paths), `provider-system` (subagents are
  child sessions)

## Background
Each subagent has its own transcript buffer, header and message input. Its
file activity does not: `_record_file_op` finds the call's tracker through
`_view_for` (the subagent's `AgentView` when a subagent owns the call), but
records into the session's one `self.file_activity`. The help says so:
"Subagent (Task) edits appear alongside the main agent's, unmarked."

Every agent gets its own tally and panel, from the same code as the main
agent's: the same `FileActivity`, and the same panel placement and lifetime
(a panel opens in a split below its agent's window, and closes when that
window closes or stops showing the agent). The main panel lists the main
agent's changes only.

The panel code holds one window and buffer per panel name (`win_nrs`,
`buf_nrs`) and one home, the chat window. A second activity buffer in those
tables would take the main slot, and `split_target` places a new panel next
to the open main panels, not below its home. So a subagent's panel needs its
own tables and home.

## Changes

### Panel home (`lua/agentic/ui/chat_widget.lua`, `widget_layout.lua`)
- Extract the home tracking ChatWidget has for the chat (`home_win`,
  `_adopt_home`, `_track_home`, `_home_in_tab`, the QuitPre close, the
  float skip) into a unit over a home buffer plus its own `win_nrs` and
  `buf_nrs`. ChatWidget uses one for the chat; it keeps its behaviour.
- Its `toggle_panel(panel, on_open, on_close)` is the one ChatWidget has
  today, over its own tables. The not-shown warning names its home.

### `lua/agentic/subagents.lua`
- `Subagents.Agent` gets `activity` (a `FileActivity`) and a panel home over
  the transcript buffer, created in `_open_agent` and
  `add_history_transcripts`. They outlive a wiped transcript; a recreated
  transcript is the new home buffer.
- The panel buffer: made lazily (`get_bufnr`), named with the transcript's
  name tail, headed with the agent's name, re-rendered on `:e` and remade
  after a wipe as the main one is (`PANEL_RELOADS`, `on_panel_buf`), with
  the session maps (`host.setup_buf`), the agent's toggle, and `to_input`
  going to `_agent_input_win(child_id)`.
- New `activity_of(tool_call_id)`: the owning agent's `activity`, else nil.
- New `toggle_activity(child_id)`: the home's `toggle_panel("activity", …)`.
  Home: a window in the current tabpage showing the transcript, current
  window first, else the message input's window.
- `_bind_agent_keymaps` binds `keymaps.widget.toggle_activity` to
  `toggle_activity(child_id)`; after `notes/REFACTOR-subagent-shared-keys.md`
  it runs on both the transcript and the input. The buffer-local map overrides the session's
  map, as `stop_generation` there does.
- `reset` closes each agent's panel and wipes its buffer.
- New `serialize_activity()`: `child_id` → `FileActivity.Data`, for the
  history sync. `add_history_transcripts` loads `record.file_activity`.

### `lua/agentic/session_manager.lua`
- `_activity_for(tool_call_id)`: `self._subagents:activity_of(id)` or
  `self.file_activity`. `_record_file_op` and `_record_shell_ops` record
  through it.
- The open and close side effects of `toggle_file_activity` (the
  `windows.activity.display` gate, reconcile and resize on open,
  `mark_viewed` and persist on close) become one helper over a tally that
  both toggles call; `Subagents` reaches it through its host.
- `_sync_history_context` writes `serialize_activity()` into each
  `history.subagents[child_id].file_activity`.

### `lua/agentic/ui/chat_history.lua`
- `ChatHistory.Subagent` gets `file_activity?: FileActivity.Data`.
- `set_subagent_task` sets `task_id` on the existing record instead of
  replacing it.

### `doc/agentic.txt`
- § `agentic-file-activity`: replace "Subagent (Task) edits appear alongside
  the main agent's, unmarked" with: each agent has its own panel, toggled
  from its transcript or input.
- § `agentic-subagents`: one line naming the panel.

### Tests
- `chat_widget.test.lua`: the extracted home keeps the chat's panel
  behaviour (existing tests pass unchanged).
- `subagents.test.lua`:
  - an op recorded for a subagent lands in its tally, not the main one;
  - after the transcript is wiped, a new op keeps the old ops;
  - the toggle in the transcript and in the input opens the subagent's
    panel below the transcript, with main panels open;
  - the panel closes when the transcript's window closes or shows another
    buffer; `reset` closes it;
  - `to_input` in the panel goes to the subagent's input.
- `chat_history.test.lua`: a subagent's `file_activity` round-trips;
  `set_subagent_task` after a sync keeps it.
- Two sessions, each with a subagent: tallies independent; closing one
  leaves the other's buffers intact.

## Expected outcome
- `<localLeader>f` in a subagent's transcript or message input shows the
  files that subagent changed, in a split below its transcript; in the main
  chat or input, the files the main agent changed.
- Both survive a resume.

## Non-goals
- A combined view of every agent's changes.
- Moving existing sessions' subagent ops out of the main tally: logs written
  before this change keep them in the main panel.

## Open questions
None.
