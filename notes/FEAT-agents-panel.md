# Plan: agents panel
Status: spec

## Relevant files
- `lua/agentic/subagents.lua` (`_set_open`, `_merge_block_fields`,
  `_new_transcript`, `_replay_transcript`, `_start_agent`, `_open_agent`,
  `add_history_transcripts`, `reset`, `forget`, `buf_of`)
- `lua/agentic/ui/subagent_transcript.lua` (`new`, `set_context`); shared with
  `lua/agentic/background_session.lua`
- `lua/agentic/ui/chat_widget.lua` (`PanelNames`, `TOGGLED_PANELS`,
  `sync_panels`, `panel_buf_opts`, `clear`, `toggle_panel`, `on_panel_buf`)
- `lua/agentic/ui/widget_layout.lua` (`StackPanel`, `sync_panel`,
  `validate_stack`, `open_buf`)
- `lua/agentic/ui/window_decoration.lua` (default headers)
- `lua/agentic/ui/tool_call_layout.lua` (`subagent_heading`)
- `lua/agentic/session_manager.lua` (`_setup_panel_buf` owners, `TodoList:new`
  getter pattern)
- `lua/agentic/utils/buffer_names.lua` (`PANELS`)
- `lua/agentic/config_default.lua` (`windows`, `agentic.UserConfig.Windows`,
  `keymaps.widget`)
- `lua/agentic/ui/todo_list.lua`: panel to copy
- `doc/agentic.txt`: `windows.stack` default, `windows` options, panel keys,
  § agentic-buffers panels paragraph, § agentic-subagents
- Skills: `subagents`, `session-lifecycle`, `rendering`; rule
  `session-isolation`

## Background
A glance at a session should show which subagents run or ended, with a name
`gf` can follow. A panel below the chat is real text and uses the existing
panel machinery; the chat buffer stays as it is.

A row stands for a subagent whose transcript is listed, or that works.
Deleting a row is `:bdelete` on its transcript (unload and unlist,
`:h agentic-buffers`), never a stop: a finished subagent can be resumed by the
main agent (`Subagents:_relay_to_agent`). The panel holds no state of its own.

Today a transcript's output reloads it after `:bd` but does not list it again
(`setup_panel_buf` never sets `buflisted`); only `:edit`/`gf` list it. So a
start must list it, or a resumed subagent's row would stay gone.

## Changes
- Panel name `agents`: `BufferNames.PANELS`, `ChatWidget.PanelNames`,
  `WidgetLayout.StackPanel`, `panel_buf_opts` (filetype), `WindowDecoration`
  default header, `_setup_panel_buf` owners, first in the default
  `windows.stack`. A toggled panel (in `TOGGLED_PANELS`, opened by
  `toggle_agents`). With `windows.agents.auto_open`, `_start_agent` opens it
  when a subagent starts work, first or again (not during a session/load
  replay), and it closes when its buffer goes blank.
- `config_default.lua`: `windows.agents = { auto_open = true, max_height = 10,
  win_opts = {} }`, class `agentic.UserConfig.Windows.Agents`, field in
  `agentic.UserConfig.Windows`; `keymaps.widget.toggle_agents =
  "<localLeader>A"`.
- `Subagents`:
  - `_order: string[]` of child ids, appended in `_open_agent`, seeded in
    `add_history_transcripts` from the history's record order.
  - `_end_state(child_id) -> string|nil`: the loop now in
    `_replay_transcript` (last `subagent_end` row → `SessionResume.end_state`);
    `_replay_transcript` calls it.
  - `entries() -> agentic.Subagents.Entry[]` (`{ child_id, state, subagent,
    name }`) in `_order`, for subagents that are `open` or whose transcript is
    listed. `state`: `working` when open, else `_end_state`, else `ended`.
    `name`: `widget:buffer_name(child_id)`.
  - `Host.agents_changed()`, called from `_set_open`, `_merge_block_fields`,
    `reset`, and the transcript's list/unlist/wipeout handlers.
  - `_start_agent`: set `buflisted` on the transcript.
- `SubagentTranscript:new`: optional `on_listed_change` callback, wired to
  buffer-local `BufAdd`/`BufDelete`/`BufWipeout`; `BackgroundSession` passes
  none.
- New `lua/agentic/ui/agents_panel.lua`, `agentic.ui.AgentsPanel`:
  - `AgentsPanel.lines(entries) -> string[]`: pure; one row each:
    `<state>  <subagent_heading(subagent)>  <name>`.
  - `AgentsPanel:new(get_buf)`, `:render(entries)`, like `TodoList`.
  - `SessionManager` renders it on `agents_changed`, after `ChatWidget:clear`,
    and on `on_panel_buf`.
- Panel keys, buffer-local, owner from
  `SessionRegistry.owner_of_buf(nvim_get_current_buf())` (no module-level
  registry):
  - `d` operator (`dd`, `d{motion}`, visual `d`) via 'operatorfunc', fixed
    key: each row in range that is `working` is kept and named in a
    `Logger.notify`; any other runs `:bdelete` on its transcript
    (`Subagents:buf_of`). The row goes through the unlist handler.
  - `gf` / `<CR>` open the row's transcript in the home window
    (`WidgetLayout.open_buf`), not in the panel window.
- `doc/agentic.txt`: the sections listed above.

## Expected outcome
- The first subagent of a chat opens the panel (with `auto_open`).
- Each row shows whether its subagent works or how it ended; `gf` opens its
  transcript.
- `dd` on a finished row unlists and unloads its transcript: the row goes, and
  `:ls` and pickers no longer list it. On the last row the panel closes.
- `:bd` on a transcript removes its row, unless its subagent still works.
- A resumed subagent is listed again, its row comes back, and the panel
  opens.
- Loading a chat that had subagents does not open the panel; toggling it
  shows their rows.
- Closing the panel with `toggle_agents` keeps it closed until a subagent
  next starts work.

## Non-goals
- No row for the main agent.
- No stop from the panel.
- opencode and mistral-vibe subagent calls have no transcript and get no row.
- Background sessions are not subagents and get no row.

## Open questions
None.
