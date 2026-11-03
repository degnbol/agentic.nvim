# Plan: one display path for main agent and subagent windows
Status: spec

Lands after `FIX-reapply-model.md`, which deletes the `_announced_model_id` dedupe and adds `_reapply_model`.

## Relevant files
- `lua/agentic/session_manager.lua` (SM)
- `lua/agentic/subagents.lua` (`Subagents`: `new`, `transcript`, `end_agent`, `forget`, `agent_of`, `agent_of_chunk`, `set_config_options`, `record_writer`, `_view_of`, `_open_agent`, `_write_row`, `_new_transcript`, `_replay_transcript`, `_start_agent`)
- `lua/agentic/ui/subagent_transcript.lua`
- `lua/agentic/ui/status_indicator.lua`
- `lua/agentic/acp/response_boundary.lua`
- `lua/agentic/acp/agent_config_options.lua`
- `lua/agentic/ui/message_writer.lua`
- `lua/agentic/ui/chat_buffer.lua` (`ChatBuffer.start`)
- `lua/agentic/ui/window_decoration.lua` (`resolve_header_text`)
- `lua/agentic/config_default.lua` (`headers`)
- Bridge source (claude-agent-acp 0.97.0, `dist/`): `native-subagents.js` (`reportModel`, `reportConfiguration`, `announce`, `routeUpdate`, `childModelOption`), `acp-agent.js` (`setSessionConfigOption`, `usage_update` sends, `plan` from `TodoWrite` and Task tools, `publishCurrentSubagentStates`), `session-mode.js` (`publishCurrent`), `subagent-replay.js` (`sendModel`)
- Tests:
  - `lua/agentic/session_manager.test.lua` (the `announce_model_loaded` cases; `with_subagents`; the `_on_agent_chunk` mocks)
  - `lua/agentic/subagents.test.lua`
  - `lua/agentic/ui/subagent_transcript.test.lua`
  - `lua/agentic/acp/response_boundary.test.lua`
  - `lua/agentic/acp/agent_config_options.test.lua`
  - `tests/integration/test_native_subagents.lua` ("a child's config options stay out of the main agent's")
  - `tests/integration/test_subagent_inputs.lua`, `tests/integration/test_buffer_lifecycle.lua`
- Skills: `session-lifecycle`, `follow` (writes go through `_schedule_follow`/`_own_edit`), `rendering`, `provider-system`, `lua-class`.
- Rule: `.claude/rules/provider-specific.md`.

## Background
The rule: the same kind of information shows the same way in the main chat and in a subagent transcript, through shared code.

SessionManager builds the main chat's writer, indicator and response boundary as its own fields. `SubagentTranscript:new` builds the same three classes a second time. `announce_model_loaded` reads `self.config_options` and `self.message_writer` (through `_resolve_model_display` and `_model_title`), so a transcript cannot use it. A subagent's own options are kept on its `Subagents.Agent` record (`set_config_options`) and never shown.

What the main chat shows of model and mode, once `FIX-reapply-model.md` lands:
- A `Loaded` line, meaning "from here on, model X": for a new session, and at the end of a load, a re-create from history or a provider switch (`_reapply_model`); a second one when a queued saved model takes effect.
- Switch notices only for changes the user makes in the picker (`as_notice`). A change the provider makes (`_handle_new_config_options`) writes nothing.
- `Loaded` lines and notices are not in the history, so a replay (`_reload_chat`) drops them.

The header (`vim.b.agentic_header`) has no room to spare; this plan adds nothing to it.

### Bridge behaviour for child sessions
From the claude-agent-acp 0.97.0 source:
- **Options.** A child's options arrive as `config_option_update` on the child session, only after the child is announced (`reportConfiguration` holds them; `announce` publishes them). The model comes from the child's responses (`reportModel` at each `message_start`), so a child has no model before its first response; hooks can give its mode and effort earlier (`subagentConfigurationHook`). Its model entry carries `value` and `name` only (`childModelOption`), no description; the value is one of the root's list.
- **Load.** The replay sends each child's model once (`sendModel`). After the load response, `publishCurrentSubagentStates` sends only a configuration that differs from the replayed one, so a live child that replayed no response can get its first model after the load.
- **Option changes.** `setSessionConfigOption` looks the id up in `this.sessions`, which holds root sessions only; a child id fails with "Session not found". Every change to a child's options comes from the provider.
- **Todos.** A child's `plan` arrives on the child session (stamped `parentToolUseId`, routed by `routeUpdate`). From Task tools it is the whole shared list of the root session (`session.taskState`); from `TodoWrite` it is the child's own list (`planEntries(chunk.input)`). `_on_session_update` renders every `plan` into the main panel, so a child's `TodoWrite` list replaces the main agent's.
- **Usage.** `usage_update` is sent for top-level messages only, on the root session.
- **Legacy mode.** `current_mode_update` is published for root sessions only.

### Inventory

| # | Info / UI element | Main agent | Subagent | Shared today? |
|---|---|---|---|---|
| 1 | Chat-style buffer setup | `ChatBuffer.setup` in `ChatWidget:new` | `ChatBuffer.setup` in `SubagentTranscript:new` | Yes |
| 2 | MessageWriter, StatusIndicator, ResponseBoundary | Built in `SessionManager:new` | Built in `SubagentTranscript:new` | Same classes, built twice |
| 3 | Message/thought chunk write | `_on_agent_chunk`, main branch: side-record drain at a response start, `write_message_chunk`, indicator `start` | `_on_agent_chunk`, transcript branch: `write_message_chunk`, indicator `reposition` | One function, two branches |
| 4 | Working indicator | `thinking` (`_dispatch_turn`, thought chunks), `generating` (message chunks, `_on_tool_call_update`, `_on_request_permission`), `busy` (`new_session`, `_do_load_acp_session`). Stopped at turn end, by `stop_generation`, `_refresh` and a permission request. | Only `generating`, from `_start_agent` to `end_agent` / `forget`. Chunks and tool updates only `reposition` it. | Same class, different state use |
| 5 | Opening line in body | `# <date> · <id8>` (`_generate_welcome_header`). Not replayed on `:e`. | `## <mode> <type> · <label>` (`write_subagent_heading`). Rewritten on `:e` (`_replay_transcript`). | No |
| 6 | Model | `Loaded` line (`announce_model_loaded`); switch notice from the picker (`_notice_model_switched`); name in the info panel | Stored on the agent record, not shown | No |
| 7 | Mode | Switch notice from the picker (`_notice_mode_switched`); name in the info panel | Stored, not shown | No |
| 8 | Thought level | On the model line and switch notice title (`_model_title`); switch notice from the picker (`_notice_thought_level_switched`) | Stored, not shown | No |
| 9 | Model/mode picker keys | `config_options:bind_keymaps` in `_setup_session_buf`, on every session buffer | Reach transcripts and message inputs; act on the **main** agent | Same keys, main target |
| 10 | Header title | `#<n> <title or Agentic Chat>` (`ChatWidget:set_chat_title`) | `#<child session id> › <heading>` (`SubagentTranscript:set_header`) | Icon shared |
| 11 | Header context | `<n>k` tokens (`_update_chat_header`) | Nil while running; the end word after the end | No |
| 12 | Header state | `running`, `idle` at an unseen turn end (`_notify_attention(true)`), `waiting` for a hidden permission float | `running`, `waiting` on the transcript. No `idle` or bell at `end_agent`. | `running`/`waiting` shared |
| 13 | Header user customisation | `Config.headers.agent` | Looked up as `subagent` / `message` (`resolve_header_text` reads `agentic_window`) | Same mechanism, separate keys |
| 14 | Buffer name | `WindowDecoration.buffer_name` | `WindowDecoration.buffer_name` | Yes |
| 15 | User prompt in body | `write_user_prompt` on submit and in load replay | The launch prompt and relayed messages are `session_message` rows (`SessionResume.write_row`) | No |
| 16 | Tool call blocks, permission float | `_writer_for`, `_indicator_for`, `_on_tool_call`, PermissionManager's writer lookup | Same path | Yes |
| 17 | Turn end | `_finalize_turn`: `finalize_turn`, `set_turn_usage` footer, side-record drain | `end_agent`: an end row (`subagent_end`) | No |
| 18 | Cancelled stamping | `_end_open_tool_calls`, `stop_generation` (`stamp_open_calls`) | `end_agent`, unless `completed` | Yes |
| 19 | Errors | `write_error_message` / `write_error_action` in the body | The end row carries the error text; the header context shows the end word | No |
| 20 | Todo list | `TodoList` on the `todos` panel, fed by every `plan` in `_on_session_update` | A child's `plan` renders into the main panel (see "Bridge behaviour") | Main panel only |
| 21 | Input | `input` panel, `Prompt` | Background only: `SubagentInput`. Blocking: the session input. | Icon shared |
| 22 | Stop key | `stop_generation` | Cancels the child session | Separate, by design |
| 23 | Re-render on `:e` | `_reload_chat` | `_replay_transcript` | Near-copy |
| 24 | Usage / tokens / `/context` | `usage_update`; `/context` | None sent for a child | n/a |
| 25 | Hook activity, loaded files | `_drain_side_records` | `_drain_subagent_side_records` applies only tool call fields | n/a |
| 26 | Title / name source | `session_info_update`, `/rename` | `subagent_update` title/description, record type/mode | No |

## Changes

### AgentView
New class `agentic.ui.AgentView` in `lua/agentic/ui/agent_view.lua`, one per agent window: the main chat and each transcript. Fields: `bufnr`, `writer`, `status_indicator`, `response_boundary`.

Options are not a view field. They belong to the agent, and a transcript lives shorter than its agent: `Subagents:transcript` builds a new one after the user wipes it. `announce_model` takes the options as an argument.

```lua
--- @param bufnr integer A chat-style buffer
--- @return agentic.ui.AgentView
function AgentView:new(bufnr)

--- Write a message or thought chunk and move a running working indicator
--- below it.
--- @param chunk agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk
--- @param starts_response boolean|nil
function AgentView:write_chunk(chunk, starts_response)

--- Reset the writer and restart the chat buffer (`ChatBuffer.start`:
--- treesitter, image attach), ready for a replay into an empty buffer.
function AgentView:restart()

--- Write `**Loaded <name>** · <id>` and the model's description.
--- @param options agentic.acp.AgentConfigOptions
--- @param model_id string|nil Nil writes nothing
--- @param fallback agentic.acp.AgentConfigOptions|nil Names and describes a model `options` lists without a description
function AgentView:announce_model(options, model_id, fallback)
```

Operations with a lower home go there:
```lua
--- Run a message chunk's text through the boundary.
--- @param update agentic.acp.AgentMessageChunk
--- @return agentic.acp.AgentMessageChunk|nil chunk `update` with the filtered text, nil when no text is left
--- @return boolean starts_response The chunk is the first text of a new response
function ResponseBoundary:filter_chunk(update)

--- Switch to `state` when the indicator is active; else do nothing.
--- @param state agentic.ui.StatusIndicator.State
function StatusIndicator:switch(state)

--- How a model id reads to a human: its display name and description. Falls
--- back to `fallback`'s entry when this one has no description, then to the id.
--- @param model_id string
--- @param fallback agentic.acp.AgentConfigOptions|nil
--- @return string name
--- @return string|nil description
function AgentConfigOptions:model_display(model_id, fallback)

--- `label`, `model_id` and, for the current model only, its thought level,
--- joined by ` · `.
--- @param label string
--- @param model_id string
--- @return string title
function AgentConfigOptions:model_title(label, model_id)
```

Sources: `filter_chunk` is the local `filter_chunk` of `session_manager.lua`; `model_display` is `_resolve_model_display`; `model_title` is `_model_title`; `announce_model` is `announce_model_loaded`. No change in what the main chat prints. `restart` is the shared start of `_reload_chat` and `SubagentTranscript:restart`: `writer:reset()`, `ChatBuffer.start`. `SubagentTranscript:restart` still empties the lines itself; `:e` has freed them for `_reload_chat`.

`model_display`'s `fallback`: a child's model entry has no description (see "Bridge behaviour"), and on the `default` entry the `Default…` name resolves only from the description. The entry's value is one of the root's list, so the main agent's options describe it.

Indicator state stays with the caller, in `_on_agent_chunk`: the main chat `start`s `thinking`/`generating` by chunk kind, as today; a transcript `switch`es, so a late chunk does not bring back an indicator `end_agent` stopped (an ended child still gets late updates).

`_notice_model_switched`, `_notice_mode_switched` and `_notice_thought_level_switched` stay in SM: they show picker changes, which only the main agent has. `_notice_model_switched` calls `model_display`/`model_title` on `self.config_options`.

### Ownership
- **SessionManager:** `main_view`, `config_options`, `todo_list`. In `_on_agent_chunk`, the side-record drain at a response start and the indicator call for each view. Header context, info panel, welcome line, `_finalize_turn`, errors and retry, `/context`, title, switch notices.
- **SubagentTranscript:** `view` in place of its `writer`/`status_indicator`/`response_boundary` fields. Its heading, header title and state, buffer name and lifecycle autocmds stay.
- **Subagents:** the agent record's `config_options`. `new(widget, main_view, host)` replaces `new(widget, chat_writer, chat_indicator, host)`; `_chat_writer`/`_chat_indicator` become `_main_view`. `_view_of` returns an AgentView; its callers `_open_agent` and `_write_row` take the view's fields. `record_writer` returns `self._main_view.writer` for a main-chat record. `Subagents.Host` gains `config_options fun(): agentic.acp.AgentConfigOptions`, the main agent's, for `fallback`.

Provider-specific code: none moves.

### Steps
1. **Add `AgentView`**, `ResponseBoundary:filter_chunk`, `StatusIndicator:switch`, `AgentConfigOptions:model_display` and `model_title`, per the `lua-class` skill. Build `self.main_view` in `SessionManager:new` from the chat buffer.
   - `self.message_writer` and `self.status_indicator` stay as references to the view's fields, set once in `new` and never reassigned. Reason: `session_recovery.lua` reads them from the session, and they name the main chat's writer and indicator at ~60 SM sites; `main_view` is the unit passed on. Delete `self._response_boundary`: its one read is the chunk path step 3 replaces.
   - `announce_model_loaded` becomes a one-line SM wrapper: `self.main_view:announce_model(self.config_options, model_id)`. `_info_snapshot` and `_notice_model_switched` call `model_display`/`model_title`; delete `_resolve_model_display` and `_model_title`.
   - Replace `_writer_for`/`_indicator_for` (a pair keyed by tool call id) with `_view_for(tool_call_id)`.
2. **SubagentTranscript owns an AgentView.** Replace its three fields with `view`. Find the callers with `rg "\.(writer|status_indicator|response_boundary)\b"` and `rg "Subagents:new|_response_boundary"`, leaving out `message_writer`/`chat_writer`. Test mocks that build `Subagents` or a transcript table change with them.
3. **One chunk path.** `_on_agent_chunk` takes the transcript `agent_of_chunk` returns (it also matches a task-tagged chunk on the root session), else `main_view`. A message chunk goes through `view.response_boundary:filter_chunk`; then `view:write_chunk`; then the indicator call (see "AgentView"). History writes and `_sync_modified`/`_history_changed` stay as now. Delete the local `filter_chunk`. `_reload_chat` and `SubagentTranscript:restart` call `restart`.
   - In `_on_tool_call_update`, a subagent's status update calls `switch("generating")` on its transcript's indicator. Rewrite the comment there that says only the main indicator follows tool activity.
4. **Subagent model line.** In `Subagents:set_config_options`, when the child had no model before `set_options` and has one after, and its agent is open with a loaded transcript, write `view:announce_model(options, id, self._host.config_options())`. Never load a transcript for it.
   - The line means "from here on, model X", which holds for a running child. A running child's transcript is loaded (`_start_agent` → `transcript`). A replayed one is unloaded on purpose and gets no line, also when its first model comes after the load response.
   - A later model or mode change writes nothing: it comes from the provider, which the main chat does not show either.
   - Like the main chat's, the line is not in the history, so `_replay_transcript` drops it.
   - Update the docstring: the method now also writes the first model line.
5. **Docs.** `doc/agentic.txt` § `agentic-subagents`: a running subagent's transcript shows its model as a `Loaded` line at its first response.

### Tests
- New `lua/agentic/ui/agent_view.test.lua`:
  - `announce_model` writes `**Loaded <name>** · <id>` plus the description line; nil writes nothing; a model without a description takes name and description from `fallback`. Port the `announce_model_loaded` cases of `session_manager.test.lua` here; keep one SM case for the wrapper.
  - `write_chunk` repositions an active indicator and changes no state.
- `response_boundary.test.lua`: `filter_chunk` drops a chunk with no text left and marks a response start.
- New `lua/agentic/ui/status_indicator.test.lua`: `switch` changes an active state and does nothing when stopped.
- `agent_config_options.test.lua`: `model_display` (the `Default…` name taken from the description; the `fallback`; the fallback to the id) and `model_title` (thought level for the current model only).
- `subagents.test.lua`: `new` with a main view; `record_writer` for a main-chat record returns the main view's writer.
- `subagent_transcript.test.lua`: the transcript's view, writer, indicator and boundary are distinct from the main view's.
- `tests/integration/test_native_subagents.lua`:
  - Extend "a child's config options stay out of the main agent's": a running child's transcript gets the `Loaded` line and the chat does not. A second update with another model or mode writes nothing.
  - The layout of a first model update followed by a thought chunk and a message chunk that starts a response: `Loaded` line, then the thought, then the message.
  - A replayed child's first model, during the load and after the load response, writes nothing and does not load its transcript.
  - A child's thought chunk switches its running indicator to `thinking`; a tool call update switches it to `generating`; a chunk after `end_agent` starts nothing.
  - A task-tagged chunk on the root session lands in its child's transcript; main and child chunks land in their own buffers.
- `make validate`.

## Expected outcome
- The main chat shows exactly what it shows today.
- A running subagent's transcript shows the model it runs, as the main chat shows a new session's.
- A transcript's working indicator shows `thinking` after a thought chunk and `generating` after a message chunk or a tool update. Unlike the main chat's, it does not stop for a permission request.
- Main and subagent windows share one display class.

## Non-goals
- Adding anything to the header (`vim.b.agentic_header`).
- Changing the subagent block in the main chat.
- Picker keys in transcripts and message inputs (inventory 9): they keep acting on the main agent. A child's options cannot be changed (see "Bridge behaviour"), and changing what the keys do there is a behaviour change, not consolidation.
- Header customisation keys (inventory 13): transcripts keep their `subagent` key; the `agent` entry's `title` would replace the transcript's `#<id> › <heading>`.
- Notices for model or mode changes the provider makes, in either window.
- Routing `usage_update` or `current_mode_update` by source session: the bridge sends neither for a child.
- A usage footer, an opening date/id line or body error messages in transcripts (inventory 5, 17, 19).
- An `idle` state or bell at `end_agent` (inventory 12). The bell signals only that user input is requested; a subagent's end requests none.
- A child's `TodoWrite` list replacing the main todos (inventory 20): `notes/bug-child-todowrite-overwrites-todos.md`.
