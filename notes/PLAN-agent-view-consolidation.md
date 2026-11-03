# Plan: one display path for main agent and subagent windows
Status: reviewed (open questions)

Lands after `PLAN-reapply-model.md`, which deletes the `_announced_model_id` dedupe, Subagent code is named as f87761d left it: class `Subagents` in `lua/agentic/subagents.lua` (`transcript`, `end_agent`, `forget`, `agent_of`, `agent_of_chunk`, `set_config_options`; private `_new_transcript`, `_replay_transcript`, `_start_agent`, `_open_input`, `_bind_agent_keymaps`).

## Relevant files
- `lua/agentic/session_manager.lua` (SM)
- `lua/agentic/subagents.lua`
- `lua/agentic/ui/subagent_transcript.lua`
- `lua/agentic/ui/subagent_input.lua`
- `lua/agentic/ui/window_decoration.lua` (`WINDOW_HEADERS`, `resolve_header_text`)
- `lua/agentic/ui/chat_widget.lua` (`set_chat_title`, `set_running`, `set_idle`, `set_waiting`)
- `lua/agentic/acp/agent_config_options.lua`
- `lua/agentic/ui/todo_list.lua`
- `lua/agentic/ui/status_indicator.lua`
- `lua/agentic/ui/message_writer.lua` (`write_subagent_heading`)
- `lua/agentic/ui/tool_call_layout.lua` (`subagent_heading`)
- `lua/agentic/session_resume.lua` (`write_row`, `replay_messages`)
- `lua/agentic/config_default.lua` (`windows.stack`, `headers`)
- Tests:
  - `lua/agentic/session_manager.test.lua` (the `announce_model_loaded`, `_notice_model_switched` and `_notice_mode_switched` cases)
  - `lua/agentic/ui/subagent_transcript.test.lua`
  - `lua/agentic/acp/agent_config_options.test.lua`
  - `tests/integration/test_native_subagents.lua` ("a child's config options stay out of the main agent's")
  - `tests/integration/test_subagent_inputs.lua`
- Consumer: `notes/feature-thought-level-display.md`.
- Skills: `session-lifecycle` (header pipeline), `follow` (writes go through `_schedule_follow`/`_own_edit`; attention badges), `rendering`, `provider-system`, `lua-class`.
- Rule: `.claude/rules/provider-specific.md`.

## Background
The rule: the same kind of information shows the same way in the main chat and in a subagent transcript, through shared code.

SessionManager builds the main chat's writer, indicator and response boundary as its own fields. `SubagentTranscript:new` builds the same three classes a second time. The model and mode display code (`_resolve_model_display`, `announce_model_loaded`, `_notice_model_switched`, `_notice_mode_switched`) reads `self.config_options`, `self.message_writer` and `self.is_generating`, so a transcript cannot use it.

A subagent already has its own options: `Subagents:set_config_options` keeps them on its `Subagents.Agent` record, read only. Nothing displays them.

The header (`vim.b.agentic_header`, rendered by incline) is short on room. Its context holds only the token count (`_update_chat_header`). Mode and model names are in the info panel (`_info_snapshot`). This plan adds nothing to the header.

### Inventory

| # | Info / UI element | Main agent | Subagent | Shared today? |
|---|---|---|---|---|
| 1 | Chat-style buffer setup | `ChatBuffer.setup` in `ChatWidget:new` | `ChatBuffer.setup` in `SubagentTranscript:new` | Yes |
| 2 | MessageWriter, StatusIndicator, ResponseBoundary | Built in `SessionManager:new` | Built in `SubagentTranscript:new` | Same classes, built twice |
| 3 | Message/thought chunk write | `_on_agent_chunk`, main branch: side-record drain at a response start, `write_message_chunk`, indicator `start` | `_on_agent_chunk`, transcript branch: `write_message_chunk`, indicator `reposition` | One function, two branches |
| 4 | Working indicator | `thinking` (`_dispatch_turn`, thought chunks), `generating` (message chunks, `_on_tool_call_update`, `_on_request_permission`), `busy` (`new_session`, `_do_load_acp_session`). Stopped at turn end (`_dispatch_turn` callback), by `stop_generation` and `_refresh`. | Only `generating`, from `_start_agent` (and from `transcript` rebuilding a wiped transcript of an open agent) to `end_agent` / `forget`. Chunks and tool updates only `reposition` it. | Same class, different state use |
| 5 | Opening line in body | `# <date> · <id8>` (`_generate_welcome_header`, from `new_session`). Not replayed on `:e` (`_reload_chat`). | `## <mode> <type> · <label>` (`SubagentTranscript:restart` → `write_subagent_heading`, `ToolCallLayout.subagent_heading`). Rewritten on `:e` (`_replay_transcript`). | No |
| 6 | Model | Body line `**Loaded <name>** · <id>` + description (`announce_model_loaded`, from `new_session` and `_handle_model_change`). Switch notice (`_notice_model_switched`). Name in the info panel. | Stored on the agent record, not shown | No |
| 7 | Mode | Switch notice from the picker (`_notice_mode_switched`). Name in the info panel. Legacy `current_mode_update` in `_on_session_update` ignores the source session. | Stored, not shown | No |
| 8 | Thought level | Stored (`AgentConfigOptions.thought_level`), not shown | Stored, not shown | n/a (separate ticket) |
| 9 | Model/mode picker keys | `self.config_options:bind_keymaps` in `_setup_session_buf`, on every session buffer | The same call reaches transcripts (`_new_transcript` → `setup_buf`) and message inputs (`_open_input`). The keys act on the **main** agent's options. | Same keys, main target |
| 10 | Header title | `#<n> <title or Agentic Chat>` (`ChatWidget:set_chat_title`), icon `Glyphs.AGENT` | `#<child session id> › <heading>` (`SubagentTranscript:set_header`), icon `Glyphs.AGENT` | Icon shared |
| 11 | Header context | `<n>k` tokens (`_update_chat_header`) | Nil while running; the end word after the end (`SubagentTranscript:set_context` from `end_agent`) | No |
| 12 | Header state | `running` (`ChatWidget:set_running`), `idle` at an unseen turn end (`_notify_attention(true)`), `waiting` for a hidden permission float (`_on_permission_hidden`) | `running` (`SubagentTranscript:set_running`), `waiting` on the transcript (`_on_permission_hidden` with its `badge_bufnr`). No `idle` or bell at `end_agent`. | `running`/`waiting` shared, `idle` main only |
| 13 | Header user customisation | `Config.headers.agent` | Looked up as `subagent` / `message` (`resolve_header_text` reads `agentic_window`). Both absent from the `headers` defaults. | Same mechanism, separate keys |
| 14 | Buffer name | `ChatWidget:set_chat_title` → `WindowDecoration.buffer_name` | `SubagentTranscript:new` (`name_tail`) → `WindowDecoration.buffer_name` | Yes |
| 15 | User prompt in body | `write_user_prompt` on submit (`_send_user_prompt`) and in load replay (`user_message_chunk`) | The launch prompt and relayed messages are `session_message` rows (`SessionResume.write_row`) in the main chat and the transcript. A child's `user_message_chunk` is skipped. | No |
| 16 | Tool call blocks, permission float | `_writer_for`, `_indicator_for`, `_on_tool_call`, PermissionManager's writer lookup | Same path | Yes |
| 17 | Turn end | `_finalize_turn`: `finalize_turn`, `set_turn_usage` footer, side-record drain | `end_agent`: an end row (`subagent_end`). No usage footer. | No |
| 18 | Cancelled stamping | `_mark_unresolved_tool_calls_cancelled` | `end_agent`, unless `completed` | Yes |
| 19 | Errors | `write_error_message` / `write_error_action` in the body (`_dispatch_turn` callback) | The end row carries the error text as its body; the header context shows the end word | No |
| 20 | Todo list | `TodoList` on the `todos` panel (`SessionManager:new`). `plan` → `todo_list:render` in `_on_session_update`, source ignored. Cleared by `new_session`, `_reset_conversation`, `switch_provider`, `respawn_preserving_history`. | Missing. A child's `plan` would render into the main panel. | No |
| 21 | Input | `input` panel, `Prompt` | Background only: `SubagentInput`, `Message to <label>`, same icon. Blocking: the session input (`_agent_input_win`). | Icon shared, code separate |
| 22 | Stop key | `stop_generation` (`_bind_owner_keymaps`) | Cancels the child session (`_bind_agent_keymaps`, `_open_input`) | Separate, by design |
| 23 | Re-render on `:e` | `_reload_chat` | `_replay_transcript` | Near-copy |
| 24 | Usage / tokens / `/context` | `usage_update` in `_on_session_update` sets `_usage` and records the account budget, source ignored. `/context` (`_display_context_usage`). | Missing | No |
| 25 | Hook activity, loaded files | `_drain_side_records` | Not shown: `_drain_subagent_side_records` applies only tool call fields | n/a |
| 26 | Title / name source | `session_info_update`, `/rename` (`_rename_session`) | `subagent_update` title/description (`Subagents:update`), record type/mode (`read_record`) | No |

## Changes

### Shared unit: `agentic.ui.AgentView` (new, `lua/agentic/ui/agent_view.lua`)
One per agent window: the main chat and each transcript. It holds the display state of one buffer: `bufnr`, `writer`, `status_indicator`, `response_boundary`.

Options and todos are not view fields. They belong to the agent, and a transcript lives shorter than its agent: `Subagents:transcript` builds a new one after the user wipes it. The view's methods take the options as an argument.

```lua
--- @param bufnr integer A chat-style buffer
--- @return agentic.ui.AgentView
function AgentView:new(bufnr)

--- Run a message chunk's text through the view's response boundary.
--- @param update agentic.acp.AgentMessageChunk
--- @return agentic.acp.AgentMessageChunk|nil chunk `update` with the filtered text, nil when no text is left
--- @return boolean starts_response The chunk is the first text of a new response
function AgentView:filter_chunk(update)

--- Write a message or thought chunk and move the working indicator below it.
--- @param chunk agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk
--- @param starts_response boolean|nil
function AgentView:write_chunk(chunk, starts_response)

--- Empty the buffer and reset its writer, ready for a replay.
function AgentView:clear()

--- Write `**Loaded <name>** · <id>` and the model's description.
--- @param options agentic.acp.AgentConfigOptions
--- @param model_id string|nil Nil writes nothing
function AgentView:announce_model(options, model_id)

--- Write a model switch notice.
--- @param options agentic.acp.AgentConfigOptions
--- @param model_id string|nil Nil writes nothing
--- @param mid_turn boolean
function AgentView:notice_model_switched(options, model_id, mid_turn)

--- Write a mode switch notice.
--- @param options agentic.acp.AgentConfigOptions
--- @param mode_id string
--- @param mid_turn boolean
function AgentView:notice_mode_switched(options, mode_id, mid_turn)
```

The model lookup reads only the options, so it moves there:
```lua
--- How a model id reads to a human: its display name and description. Falls
--- back to the id for a model the provider never described.
--- @param model_id string
--- @return string name
--- @return string|nil description
function AgentConfigOptions:model_display(model_id)
```

Sources: `filter_chunk` is the local `filter_chunk` of `session_manager.lua`; `model_display` is `_resolve_model_display`; the three writers are `announce_model_loaded`, `_notice_model_switched` and `_notice_mode_switched`. No change in what they print. `write_chunk` does not switch the indicator state; that stays with the owner until Open question 4 is answered. `clear` is the shared start of `_reload_chat` and `SubagentTranscript:restart`: `writer:reset()`, `ChatBuffer.start`, empty lines.

What each owner keeps:
- **SessionManager (main):**
  - `main_view`, `config_options`, `todo_list` and the todos panel.
  - In `_on_agent_chunk`: the side-record drain at a response start, between `filter_chunk` and `write_chunk`, and the `start("generating"|"thinking")` call.
  - Header context (`_update_chat_header`), info panel, welcome line, `_finalize_turn`, errors and retry, `/context`, title.
- **SubagentTranscript:** `view` in place of its `writer`/`status_indicator`/`response_boundary` fields. Its heading, header title and state, buffer name and lifecycle autocmds stay.
- **Subagents:** the agent record's `config_options` (and its todos, Open question 3).
- `_writer_for`, `_indicator_for`, `_writer_of_buf` and `_on_agent_chunk` choose a view, then use its fields.

Provider-specific code: none moves. `subagent_task_id`, `subagent_record` and friends stay behind `self.agent` (adapter methods).

### Steps
1. **Add `AgentView`** and `AgentConfigOptions:model_display`, as classes per the `lua-class` skill. Build `self.main_view` in `SessionManager:new` from the chat buffer.
   - `self.message_writer`, `self.status_indicator` and `self._response_boundary` become references to the view's fields, set once in `new`. None is ever reassigned, so their ~60 SM uses and the uses in `session_recovery.lua` and PermissionManager keep working.
   - `announce_model_loaded`, `_notice_model_switched` and `_notice_mode_switched` become one-line SM wrappers over `main_view`, passing `self.config_options` and `self.is_generating`: `_handle_model_change`, `_handle_mode_change`, `new_session` and the `session_manager.test.lua` cases call them. `_info_snapshot` calls `model_display`; delete `_resolve_model_display`.
2. **SubagentTranscript owns an AgentView.** Replace its three fields with `view`. Update the callers found by `rg "transcript(\(\w*\))?\.(writer|status_indicator|response_boundary)"` in SM, `subagents.lua` and about 15 test lines.
3. **One chunk path.** `_on_agent_chunk` takes `main_view`, or the view of the transcript `agent_of_chunk` returns. A message chunk goes through `view:filter_chunk`; then `view:write_chunk`. History writes and `_sync_modified`/`_history_changed` stay as now. Delete the local `filter_chunk`. `_reload_chat` and `SubagentTranscript:restart` call `clear`.
4. **Route by source session.** In `_on_session_update`, `plan`, `current_mode_update` and `usage_update` resolve the agent with `agent_of(source_session_id, self.agent:subagent_task_id(update))`. `config_option_update` already routes by source. The main agent's updates act as today.
   - A child `plan`: kept on the agent record, shown per Open question 3. Before writing this step, check bridge 0.95.0 for how a child's TodoWrite arrives (`plan` on the child session, or on the root with `parentToolUseId`).
   - A child `current_mode_update`: goes to the `legacy_agent_modes` of the record's options.
   - A child `usage_update`: still `Budget.record` its budget windows, which are the account's. It does not set `_usage` or the main header. What else shows it is Open question 6.
5. **Subagent model line.** In `Subagents:set_config_options`, read `current_model_id()` before and after `set_options`. Nil before, set after: `view:announce_model(options, id)`. Set before and a different id after: `view:notice_model_switched(options, id, agent.open)`. The same id writes nothing, so no dedupe field is needed. Write through `transcript(child_id)`, which loads an unloaded transcript first. Options of a child not announced yet are dropped today (`set_config_options` logs them); check against the bridge that a child's first `config_option_update` follows its `subagent_update`, else the model line never shows.
6. **Subagent todos.** Depends on Open question 3. TodoList needs no change: each instance takes its own buffer getter (`TodoList:new(get_bufnr, on_change, on_close)`).
7. **Docs.** `doc/agentic.txt` § `agentic-subagents`: the transcript shows the model line and switch notices, and its own todos once step 6 lands.

### Tests
- New `lua/agentic/ui/agent_view.test.lua`:
  - `announce_model` writes `**Loaded <name>** · <id>` plus the description line; nil writes nothing.
  - `notice_mode_switched` uses the mode description.
  - `filter_chunk` drops a chunk with no text left and marks a response start.
  - Port the `announce_model_loaded`, `_notice_model_switched` and `_notice_mode_switched` cases of `session_manager.test.lua` here. Keep one SM case per wrapper.
- `agent_config_options.test.lua`: `model_display`, with the `Default…` name taken from the description, and the fallback to the id.
- `subagent_transcript.test.lua`: the transcript's view, writer, indicator and boundary are distinct from the main view's.
- `tests/integration/test_native_subagents.lua`:
  - Extend "a child's config options stay out of the main agent's": the transcript gets the `Loaded` line and the chat does not. A second update with another model writes a switch notice; one with the same model writes nothing.
  - A child's `plan` does not change the main todos buffer.
  - A child's `usage_update` does not change the main header context.
  - A child's `current_mode_update` does not change the main agent's legacy mode.
  - Message chunks for main and child land in their own buffers.
- `make validate`.

## Expected outcome
- The main chat shows exactly what it shows today.
- A subagent transcript shows its model as the main chat shows the main agent's: a body line, then switch notices.
- A subagent's todos, legacy mode and token count no longer overwrite the main agent's.
- Main and subagent windows share one display class.

## Non-goals
- Adding anything to the header (`vim.b.agentic_header`).
- Thought-level display (`notes/feature-thought-level-display.md`). Once it lands, both windows get it through `AgentView`.
- Changing the subagent block in the main chat.

## Open questions
1. **Picker keys in a transcript.** Change-mode and switch-model in a transcript or message input act on the main agent today (`_setup_session_buf` binds `self.config_options:bind_keymaps` on them). A subagent's own options are read only (`set_config_options`). Should these keys act on the subagent, on the main agent, or do nothing there? Whether the bridge accepts `session/set_config_option` for a child session id has not been checked.
2. **Subagent mode.** The main agent's mode name is in the info panel. The transcript header carries the heading (spawn mode `background`/`blocking`, type, label) and, after the end, the end word. Should a subagent's permission mode be shown, and where?
3. **Subagent todos panel placement and lifetime.** The main todos panel is in the widget's stack (`windows.stack`), opens on a non-empty render and closes when all items are done (`close_if_all_completed`, on submit). Transcripts open in any window (`WidgetLayout.open_buf`). Where does a subagent's todos window open, when does it open and close, and does it outlive the subagent?
4. **Indicator states.** The main indicator switches between `thinking` and `generating` per chunk kind. A transcript shows `generating` from `_start_agent` to `end_agent`. Should the transcript follow the main agent's rule?
5. **End-of-run signals.** The main agent sets `idle` and rings the bell when a turn ends unseen (`_notify_attention(true)`). `end_agent` gives neither, only an end row and the header context. Should a subagent's end signal the same way, and in which buffer?
6. **Info the main chat has and the transcript lacks.** For each, should the transcript show it?
   - Errors in the body: a subagent's failure appears as the end row's body.
   - The per-turn usage footer (`set_turn_usage`), and a child's token count.
   - An opening date/id line: the transcript opens with a `##` heading.
7. **Model line on reload.** `Loaded` lines and notices are not in the history, so `_reload_chat` drops them, and `_replay_transcript` (also run when a wiped transcript is rebuilt) would too. Should the model line be replayed, in both?
8. **Header customisation keys.** `Config.headers` is keyed per panel. The transcript looks up `subagent` and the message input `message`; neither is in the defaults. Should the transcript use the `agent` entry, or keep its own key?
