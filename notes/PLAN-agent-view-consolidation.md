# Plan: one display path for main agent and subagent windows
Status: draft

## Relevant files
Lines are in `lua/agentic/session_manager.lua` (SM) unless another file is named.
- `lua/agentic/session_manager.lua` (SM)
- `lua/agentic/ui/subagent_transcript.lua`
- `lua/agentic/ui/subagent_input.lua`
- `lua/agentic/ui/window_decoration.lua`
- `lua/agentic/ui/chat_widget.lua`
- `lua/agentic/acp/agent_config_options.lua`
- `lua/agentic/ui/todo_list.lua`
- `lua/agentic/ui/status_indicator.lua`
- `lua/agentic/ui/message_writer.lua`
- `lua/agentic/ui/tool_call_renderer.lua` (:360-392)
- `lua/agentic/session_restore.lua` (:375)
- `lua/agentic/config_default.lua` (:198-221, :437-444)
- Tests:
  - `lua/agentic/session_manager.test.lua` (:77, :147, :1120-1290)
  - `lua/agentic/ui/subagent_transcript.test.lua` (:127-213)
  - `lua/agentic/ui/window_decoration.test.lua`
  - `lua/agentic/ui/todo_list.test.lua`
  - `tests/integration/test_native_subagents.lua`
  - `tests/integration/test_subagent_inputs.lua`
- Consumers: `notes/PLAN-rfd-subagents.md` (Step 1 item 2, the config_option_update table) and `notes/feature-thought-level-display.md`.
- Skills: `session-lifecycle` (header pipeline), `follow` (writes go through `_schedule_follow`/`_own_edit`; attention badges), `rendering`, `provider-system`, `lua-class`.
- Rule: `.claude/rules/provider-specific.md`.

## Background
The rule: the same kind of information shows the same way in the main chat and in a subagent transcript, through shared code.

Today SessionManager builds the main chat's display pieces as its own fields. SubagentTranscript builds the same classes a second time. The model and mode display code reads `self.message_writer`, `self.config_options` and `self._announced_model_id` directly, so a transcript cannot use it.

The header (`vim.b.agentic_header`, rendered by incline) is short on room. This plan adds nothing to it.

### Inventory

| # | Info / UI element | Main agent | Subagent | Shared today? |
|---|---|---|---|---|
| 1 | Chat-style buffer setup | `ChatBuffer.setup(chat)` `chat_widget.lua:1440` | `ChatBuffer.setup(bufnr)` `subagent_transcript.lua:55` | Yes |
| 2 | MessageWriter | SM:412-414 (with a `home_win` callback) | `subagent_transcript.lua:69` (no callback) | Same class, built twice |
| 3 | Response boundary | SM:393 | `subagent_transcript.lua:75` | Same class, built twice |
| 4 | Message/thought chunk write | SM:1378-1381, SM:1406-1409 | SM:1375-1377, SM:1403-1405 | Two branches per chunk type |
| 5 | Working indicator | Built SM:411. States: `thinking` (SM:3608, :1408), `generating` (SM:1380, :2261, :2499), `busy` (SM:3819, :4047). Stopped at turn end (SM:3739) and by `stop_generation` (SM:3187). | Built `subagent_transcript.lua:68`. Only `generating`, from spawn (SM:1035, :789) to close (SM:1076). Repositioned only on chunks (SM:1377, :1405), never switched to `thinking`. | Same class, different state use |
| 6 | Opening line in body | `# <date> · <id8>` (SM:193, :3916-3923). Not replayed on `:e` (SM:687-689). | `## <mode> <type> · <label>` (`subagent_transcript.lua:129-131`, `tool_call_renderer.lua:380-392`). Rewritten on `:e` (SM:767). | No |
| 7 | Model | Body line `**Loaded <name>** · <id>` + description (SM:2756-2770), at session start (SM:3931-3938) and pending-model flush (SM:2595). Switch notice (SM:2781-2801). Not in header (SM:2650-2651). Deduped on `_announced_model_id` (SM:358, :2757, reset SM:3817). | Missing. A child's `config_option_update` reaches `_handle_new_config_options` on the main options (SM:1491-1492, source ignored). | No |
| 8 | Mode | Header context, non-default only (SM:2653-2662). Switch notice on picker (SM:2550-2552, :2807-2823). Legacy `current_mode_update` (SM:1482-1490, source ignored). | Missing | No |
| 9 | Thought level | Stored (`agent_config_options.lua:99-100`), not shown | Missing | n/a (separate ticket) |
| 10 | Model/mode picker keys | `config_options:bind_keymaps` on every session buffer (SM:546) | Bound on transcripts (SM:740) and message inputs (SM:1213) through the same `_bind_session_keymaps`. They act on the **main** agent's options (`agent_config_options.lua:53-71`). | Same keys, main target |
| 11 | Header title | Session title or `Agentic Chat`, with glyph U+F0EDE (`chat_widget.lua:1545-1563`) | `Glyphs.KIND.subagent` (U+F06A9) and the heading (`subagent_transcript.lua:137-144`) | No |
| 12 | Header context | Mode, changed-file count (glyph at SM:2673), `<n>k` tokens, budget (SM:2647-2720) | Nil while running (`subagent_transcript.lua:81`). The raw `SubagentState` string after close (SM:1088). | No |
| 13 | Header badge | `[idle]` at turn end (SM:3744 → SM:136-161). Bell-only `[?]` for a visible float (SM:2281). `[?]` on `badge_bufnr` for a hidden float (SM:169-171). | `[?]` when its request is hidden (`permission_manager.lua:41`, :912-916). Cleared SM:426-433. No `[idle]`/bell when it ends (`_end_agent`). | `[?]` shared, `[idle]` main only |
| 14 | Header user customisation | `Config.headers.agent` (`window_decoration.lua:78-83`, `config_default.lua:437-444`) | Keyed `subagent` / `message` (`agentic_window`, `chat_widget.lua:1488`). Absent from defaults. | Same mechanism, separate keys |
| 15 | Buffer name | `agentic://<id>/agent/<title>` (`chat_widget.lua:1566-1569`) | `agentic://<id>/subagent/<id8>[-gN]-<label>` (`subagent_transcript.lua:36-42`, :56-66) | `WindowDecoration.buffer_name` shared |
| 16 | User prompt in body | `write_user_prompt` on submit (SM:3570) and in load replay (SM:1467) | The launch prompt is the block body in the main chat (SM:1017). Its `user_message_chunk` is skipped (SM:1449-1454). A message relayed to it shows as the relay instruction in the **main** chat (`_relay` SM:3072-3077 → SM:3570). | No |
| 17 | Tool call blocks, permission float | `_writer_for`/`_indicator_for` (SM:862-879), `_on_tool_call` (SM:1975), PermissionManager writer lookup (SM:416-422) | Same path | Yes |
| 18 | Turn end | `_finalize_turn`: `finalize_turn` + `set_turn_usage` footer + hook records (SM:2386-2395) | `writer:finalize_turn()` only (SM:1080). No usage footer. | Partly |
| 19 | Cancelled stamping | `_mark_unresolved_tool_calls_cancelled` (SM:2372-2380) | `_stamp_cancelled` at close unless completed (SM:1077-1079) | Yes (SM:2343-2364) |
| 20 | Errors | `write_error_message` in body (SM:3689), `write_error_action` (SM:3695) | End state → an end row with the error text as its body, and the header context (`_end_agent`). | No |
| 21 | Todo list | `TodoList` on `widget.buf_nrs.todos` (SM:528-534). `plan` → `todo_list:render` (SM:1357-1360), source ignored. Cleared SM:3000, :4022, :4215, :4324, `session_recovery.lua:429`. | Missing. A `plan` update from a child session would render into the main panel (SM:1357). | No |
| 22 | Input | `input` panel, `Prompt` with glyph U+F09A8 (`window_decoration.lua:15`) | Background only: `SubagentInput`, `Message to <label>` with the same glyph (`subagent_input.lua:34`, SM:1183-1231). Blocking: the session input (SM:1239-1245). | Glyph shared, code separate |
| 23 | Stop key | `stop_generation` (SM:3180-3194) | Transcript SM:1274-1285; message input SM:1214-1221 | Separate |
| 24 | Re-render on `:e` | `_reload_chat` (SM:690-699) | `_replay_transcript` (SM:764-774) | Near-copy |
| 25 | Usage / tokens / `/context` | `usage_update` (SM:1493-1507, source ignored), `/context` notice (SM:1556-1593) | Missing | No |
| 26 | Hook activity regions | `_drain_hook_records` (SM:2320, :2394, :2506-2514) | Excluded on purpose (SM:2502-2505) | n/a |
| 27 | Title / name source | `session_info_update` (SM:1508-1515), `/rename` (SM:1605) | Spawn `name` (SM:999), record `agent_type`/mode (SM:925-929) | No |

## Changes

### Shared unit: `agentic.ui.AgentView` (new, `lua/agentic/ui/agent_view.lua`)
One per agent window: the main chat and each transcript. It holds:
- `bufnr`
- `writer`
- `status_indicator`
- `response_boundary`
- `config_options` (`AgentConfigOptions`)
- `todo_list` (`TodoList`, or nil until it has a panel buffer)
- `_announced_model_id`

Methods. These are moves of existing code plus one extraction, with no change in what they print:
- `AgentView:new(bufnr, opts)`. `opts.home_win` is passed to `MessageWriter:new` as SM:412-414 does today.
- `resolve_model_display(model_id)` ← SM:2727-2740.
- `announce_model(model_id)` ← SM:2756-2770, including the dedupe.
- `notice_model_switched(model_id, mid_turn)` ← SM:2781-2801.
- `notice_mode_switched(mode_id, mid_turn)` ← SM:2807-2823.
- `mode_label()` → `string|nil` ← SM:2655-2661, the non-default rule.
- `write_chunk(update, kind)` ← the writer, boundary and indicator part of SM:1365-1381 / SM:1401-1409 (`filter_chunk` moves with it). The indicator behaviour stays per owner until Open question 4 is answered: the view takes a flag or callback for "start state on chunk".
- `reset_turn_display()`: `writer:reset()` + `ChatBuffer.start` + replay (shared core of SM:690-699 and SM:764-774).

What each owner keeps:
- **SessionManager (main):**
  - Session-wide header parts: file count, tokens, budget (SM:2664-2716). `_update_chat_header` becomes `{ main_view:mode_label(), <session parts> }`.
  - Welcome line (SM:193).
  - Usage footer and hook drain (`_finalize_turn`).
  - Errors and retry (SM:3687-3726).
  - `/context`.
  - Title / `session_info_update`.
  - The todos panel of the widget.
- **SubagentTranscript:**
  - Its `##` heading (`subagent_transcript.lua:123-132`).
  - Header title and state (`set_header`, :137-144).
  - Buffer naming.
  - Lifecycle autocmds.
  - It owns an `AgentView` in place of its `writer`/`status_indicator`/`response_boundary` fields. Keep those three names as accessors, or update their ~20 call sites in SM (`rg "transcript\.(writer|status_indicator|response_boundary)"`).
- **SessionManager subagent code:** `_view_of(child_id|nil)` replaces the writer and indicator choice in `_writer_for`, `_indicator_for`, `_chunk_agent` and `_writer_of_buf` (SM:844-879, :1340-1350).

Provider-specific code: none moves. `subagent_task_id`, `subagent_record` and friends stay behind `self.agent` (adapter methods).

### Steps
1. **Add `AgentView`** with the methods above, as a class per the `lua-class` skill. Main only: build `self.main_view` in `SessionManager:new` from the existing chat buffer.
   - Make `self.message_writer`, `self.status_indicator`, `self._response_boundary`, `self.config_options` and `self.todo_list` refer to the view's fields. Existing callers and tests keep working.
   - Move `announce_model_loaded`, `_notice_model_switched`, `_notice_mode_switched` and `_resolve_model_display` to the view. Keep thin SM wrappers, because `session_manager.test.lua:1126-1282` binds these names.
   - SM:3817 resets `main_view._announced_model_id`.
2. **SubagentTranscript owns an AgentView.** Replace the fields at `subagent_transcript.lua:68-75`. The view's `config_options` is a new `AgentConfigOptions`. Its callbacks depend on Open question 1; until it is answered, pass callbacks that log via `Logger.debug` and change nothing.
3. **One chunk path.** SM:1361-1421 calls `self:_view_of(child_id):write_chunk(...)`. History writes and `_sync_modified`/`_history_changed` stay in SM as now. Merge `_writer_for`/`_indicator_for` through `_view_of`. `_reload_chat` and `_replay_transcript` share `reset_turn_display`.
4. **Route by source session.** `plan` (SM:1357), `config_option_update` (SM:1491), `current_mode_update` (SM:1482) and `usage_update` (SM:1493) resolve the agent with `_agent_of(source_session_id, self.agent:subagent_task_id(update))`. A subagent's update goes to its view; the main agent's to `main_view`.
   - Before writing this step, check bridge 0.95.0 for how a child's TodoWrite arrives (`plan` on the child session, or on the root with `parentToolUseId`). The established fact is only that the list is the child's own.
   - A child `usage_update`: keep it off the main header. What, if anything, shows it is Open question 6.
5. **Subagent model line.** When a subagent view's options first carry a model, call `view:announce_model(id)`. On a later change, call `view:notice_model_switched(id, true)`. This is the same body text as the main chat.
6. **Subagent todos.** A subagent view gets a `TodoList` on its own todos buffer, which goes with the subagent's windows. Creating the buffer and showing it depend on Open question 3. TodoList itself needs no change: it is already per-buffer (`todo_list.lua:19`).
7. **Docs.**
   - `doc/agentic.txt` § `agentic-subagents`: the transcript shows the model line, plus its own todos once step 6 lands.
   - `session-lifecycle` skill: `_announced_model_id` moves to AgentView.
   - Update the table in `notes/PLAN-rfd-subagents.md` to point at AgentView.

## Tests
- New `lua/agentic/ui/agent_view.test.lua`:
  - `announce_model` writes `**Loaded <name>** · <id>` plus the description line, and dedupes a repeat.
  - `notice_model_switched` does not dedupe and updates the announced id.
  - `notice_mode_switched` uses the mode description.
  - `mode_label` hides `default`/`build` and strips ` Mode`.
  - Port the cases at `session_manager.test.lua:1120-1290` here. Keep one SM test per wrapper.
- `session_manager.test.lua`: `_update_chat_header` output is unchanged for main (:77, :147 fixtures).
- `subagent_transcript.test.lua`:
  - The heading and header cases (:127-213) are unchanged.
  - New: the transcript has its own view, whose writer, indicator and boundary are distinct from the main view's.
- `tests/integration/test_native_subagents.lua`:
  - A child's `config_option_update` leaves `main_view.config_options` unchanged and writes the model line in the transcript only.
  - A child's `plan` does not change the main todos buffer.
  - A child's `usage_update` does not change the main header context.
  - Message chunks for main and child land in their own buffers (regression for step 3).
- `make validate`.

## Expected outcome
- The main chat shows exactly what it shows today.
- A subagent transcript shows its model as the main chat shows the main agent's: a body line, then switch notices.
- Its updates no longer overwrite the main agent's options, todos or token count.
- Main and subagent display code is one class.

## Non-goals
- Adding anything to the header (`vim.b.agentic_header`).
- Thought-level display (`notes/feature-thought-level-display.md`). Once it lands, both windows get it through `AgentView`.
- The RFD wire change (`notes/PLAN-rfd-subagents.md`).
- Changing the subagent block in the main chat.

## Open questions
1. **Picker keys in a transcript.** Change-mode and switch-model in a transcript or message input act on the main agent today (SM:546, :740, :1213; `agent_config_options.lua:53-71`). Once a subagent has its own options, should these keys act on the subagent, on the main agent, or do nothing there? Whether the bridge accepts `session/set_config_option` for a child session id has not been checked.
2. **Subagent mode.** The main agent's non-default mode is in the header context (SM:2653-2662). The transcript header already carries the title and, after close, the state (`subagent_transcript.lua:137-144`, SM:1088). Should a subagent's mode be shown, and where?
3. **Subagent todos panel placement and lifetime.** The main todos panel lives in the widget's stack (`config_default.lua:199`), opens on a non-empty render (SM:528-531) and closes when all items are done (SM:3000). Transcripts open in arbitrary windows (`WidgetLayout.open_buf`, SM:435-437). Where does a subagent's todos window open, when does it open and close, and does it outlive the subagent?
4. **Indicator states.** The main indicator switches between `thinking` and `generating` per chunk kind (SM:1380, :1408). A transcript shows `generating` from spawn to end (SM:1035). Should the transcript follow the main agent's rule?
5. **End-of-run signals.** The main agent gets `[idle]` and a bell when a turn ends (SM:3744). A subagent's end gives neither (`_end_agent`), only an end row and the header context. Should a subagent's end signal the same way, and in which buffer?
6. **Info the main chat has and the transcript lacks.** For each, should the transcript show it?
   - Errors in the body (SM:3689): a subagent's failure appears as an end row and the header context.
   - The per-turn usage footer (SM:2388).
   - An opening date/id line (SM:193): the transcript opens with a `##` heading instead.
7. **Model line on reload.** The main chat drops the `Loaded` line on `:e` (SM:687-689); the transcript rewrites its heading (SM:767). Should the model line be replayed, in both?
8. **Header customisation keys.** `Config.headers` is keyed per panel, and the defaults omit `subagent` and `message` (`config_default.lua:437-444`). Should the transcript use the `chat` entry, or keep its own key?
