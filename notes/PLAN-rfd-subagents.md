# Plan: native subagents on the RFD form (`subagent_update`, `session_message`)
Status: draft

## Relevant files
- `lua/agentic/acp/acp_client.lua` (:130-136 capabilities, :626-628 child→root map, :1661-1683 types, :984 permission routing)
- `lua/agentic/session_manager.lua` (:706 `_agent_block`, :951 `_update_agent_block`, :969 `BLOCK_STATUS_OF_STATE`, :985 `_open_agent`, :1067 `_close_agent`, :1113 `_reset_subagents`, :1423-1440 dispatch, :1491 config options)
- `lua/agentic/ui/message_writer.lua` (:97 `SubagentInfo`, :104 `ToolCallBase`, :2802 `update_tool_call_block`)
- `lua/agentic/ui/tool_call_renderer.lua` (:1356-1380 SubAgent body fence and fold)
- `lua/agentic/ui/chat_history.lua` (:186 `set_subagent_task`, :237 `update_tool_call`)
- `doc/agentic.txt` (:78-81 bridge pin, :1027-1060 `agentic-subagents`)
- Tests: `lua/agentic/acp/acp_client.test.lua` (:1060 `spawn`), `tests/integration/test_native_subagents.lua` (:7-65 SETUP, :348-357 load fixtures), `tests/integration/test_subagent_inputs.lua` (:40-48), `tests/integration/test_goto_file.lua` (:174), `tests/integration/test_buffer_lifecycle.lua` (:446)
- Bridge 0.95.0 (`~/.local/share/npm/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist`): `acp-subagents.js:4-8`, `native-subagents.js` (:172-275 `routeUpdate`, :98-119 `reportModel`, :140-171 `publishConfiguration`, :812-819 `reportState`, :884-955 hidden launch and hand-back, :1132-1179 announce, :1218-1304 messages, :1338-1376 `rfdEndState`, `rfdLabels`), `subagent-replay.js`, `acp-agent.js:6893-7006` (replay form dispatch)
- Schema: `node_modules/@agentclientprotocol/sdk/schema/v1/schema.unstable.json` `$defs.SubagentUpdate`, `SessionMessage`, `StateUpdate`
- Skills: `provider-system` § Subagents are child sessions, `rendering`, `session-lifecycle`, `follow`; global `acp` → `references/claude-agent.md` § Native subagent sessions (stale, see Non-goals)

## Background
The plugin implements native subagents on the bridge's AIR draft: `subagent_spawned` / `subagent_state_update` (`session_manager.lua:1423-1440`). The installed bridge is 0.95.0; the doc pin is 0.85.1 (`doc/agentic.txt:78`). 0.95.0 chooses a form per client (`acp-subagents.js:4-8`): `subagents = {}` without `_meta.jetbrains.air` gets the **RFD form**. The plugin sends exactly that (`acp_client.lua:136`). So the whole subagent feature is dead, not only two update types:

1. No `subagent_spawned` → `ACPClient._children` is never filled (`acp_client.lua:626`). Every child-session notification has no subscriber and is dropped at `Logger.debug` (`:269-271`). That is why only the root-session updates warned.
2. A child's permission request finds no subscriber and is answered `cancelled` (`acp_client.lua:984-991`). Subagents cannot run any tool that asks.
3. The Agent/Task call is hidden until its final update (`native-subagents.js:897-900`). If the child was announced, the call is replaced by session messages (`:905-911`). The SubagentHandback call is also hidden (`:926-955`). So the chat shows nothing for the launch.
4. RFD-only `config_option_update`s carry a child's model. They come on the root session with `_meta.claudeCode.parentToolUseId` (`:98-119`), or on the child session (`:158-165`). Once child routing works, both reach `_handle_new_config_options` (`session_manager.lua:1491`). Then the main header's model list becomes a one-entry list with the child's model.

The shapes on v1 (the plugin negotiates `protocolVersion = 1`, `acp_client.lua:118`; v2 `state_update` on the child's own stream is `v2/session-update.js` only, so it does not apply here):

- `subagent_update {sessionId = child, title?, description?, capabilities?, state?}` on the parent session. The first one announces the child as `running` with `capabilities.cancel` (`native-subagents.js:1140-1149`). Later ones carry only `state` (`:817`). Patch semantics: omitted keeps the value, `null` clears it (schema `SubagentUpdate`). `title` is `"<name> (<role>)"` or the role. `description` is the Agent call's description (`rfdLabels`, `:1364-1376`).
- `state` is `{state = "running"|"requires_action"}`, `{state = "idle", stopReason? = "end_turn"|"cancelled"|"error", error?}` or `{state = "unknown"}` (`rfdEndState`, `:1338-1357`). If `idle` has no `stopReason`, the work ended for a reason that is not known (stream end, worker restart).
- An idle child is **reusable**. A SendMessage resume keeps the same child session id and reports `running` again (`resumeChild`, `:760-778`). The AIR `:generation:N` ids are AIR-only (`:1107-1122` is reached only from `openGeneration`/`restoreAgent`).
- `session_message {messageId, senderSessionId?, recipientSessionId?, content[], recipientMessageId?, senderMessageId?}`:
  - Launch prompt: a linked pair (`linkedSessionMessages`, `:1250-1267`). The sender's view goes on the parent with `recipientMessageId`, then the recipient's view goes on the child with `senderMessageId`. `messageId` is the launch tool-use id (the Task id).
  - Hand-back report: the same pair, from child to parent. `messageId` is the SubagentHandback tool-use id (`:946-951`).
  - `launchReply`: a foreground child's answer, on the parent only, `messageId = "<launchId>:reply"` (`:1290-1304`). The child's transcript already has that answer as its own agent text.
  - Resume prompt or SendMessage delivery: on the child only, unlinked (`:1230-1239`). The SendMessage call stays visible in the sender.
- Load replay uses the same shapes (`subagent-replay.js:67-82, 172-182, 217-256`), and a final `subagent_update` state for each child.

A rejected alternative is to declare `_meta.jetbrains.air` to keep the old form. That opts into every AIR extension (`air-extension.js:107-117`), and the bridge keeps AIR as a vendor draft beside the schema's RFD.

## Changes

### Step 1 (minimal): parity with the AIR behaviour, plus prompt and report in the chat
1. **`acp_client.lua`**
   - `:626-628`: record `self._children[update.sessionId] = root` when `session_update_type == "subagent_update"`, `update.sessionId ~= session_id` and `self.subscribers[root]` is set. Nested children resolve because the bridge announces the parent first (schema `SubagentUpdate` description).
   - Replace the `SubagentSpawned`/`SubagentStateUpdate` types (:1661-1683) with `agentic.acp.SubagentUpdate`, `agentic.acp.SubagentWorkState` (the `StateUpdate` union) and `agentic.acp.SessionMessage`. Update the alias at :1685.
   - Update the comment at :134-135.
2. **`session_manager.lua`**: dispatch `subagent_update` → `_on_subagent_update(update, source_session_id)`, and `session_message` → `_on_session_message(update, source_session_id)`. Remove the two AIR branches and `BLOCK_STATUS_OF_STATE`.
   - `_on_subagent_update`:
     - Unknown child: `_open_agent(child_id, label, source_session_id)`, with `label = description or title or agent id`. The block opens with no body, because the prompt comes as a session message.
     - Known child: apply `title`/`description` to the block's `SubagentInfo.label` when given (`vim.NIL` clears it, so fall back).
     - `state`: `running`/`requires_action` on a closed agent → `_reopen_agent(child_id)`. `idle` or `unknown` → `_close_agent(child_id)`.
     - How the block presents the state: open design decision, see Open questions.
     - `state.error.message`, when present, goes into the block footer via the existing `failure_reason` path.
     - While `self._loading`, a state only sets the block status, as `:1430-1436` does today.
   - `_open_agent(child_id, label, parent_session_id)`: replaces the `name, task` parameters. It stores `parent_session_id` on `_agents[child_id]`, and the block has `body = nil`.
   - `_reopen_agent(child_id)`: `agent.open = true`, block `in_progress`, transcript indicator `start("generating")`, `transcript:set_header(subagent)`, `_open_input(child_id)`. It replaces the new-generation path, and `_show_generation` is no longer called for this bridge.
   - `_on_session_message`:
     - The child of a message is the one of `recipientSessionId`/`senderSessionId` that is in `_agents` and whose `parent_session_id` is the other id. If there is none, the message is not about a parent/child link (step 2): `Logger.debug` and return.
     - Show each `messageId` once: `self._shown_messages[messageId] = source_session_id` the first time. Skip a later view from another session (the linked twin). A repeat from the same session is an upsert (schema `SessionMessage`): `Logger.debug` in step 1.
     - To the child, the message is the prompt. If the block has no body, set the body to the text and call `_note_agent_task(child_id, messageId)`. The launch id is now on the wire, before any meta file.
     - From the child, the message is a reply or report. Append the text to the block's `reply`.
     - Text is the joined `text` content blocks; the bridge sends no other type (`native-subagents.js:1237`, `:1256`, `:1311-1315`).
   - `_update_agent_block`: also accepts `body` and `reply`. For history, it passes the **merged** values from `message_writer.tool_call_blocks[child_id]`, not the partial (provider-system § Read completed calls from the tracker). `ChatHistory:update_tool_call` deep-extends, so a partial list would merge by index.
   - `_reset_subagents` also clears `_shown_messages`.
   - A subagent's `config_option_update` (on its own session, `native-subagents.js:140-168`, or on the root with `parentToolUseId`, `:97-119`) goes to that subagent's own `AgentConfigOptions`, not the main agent's (Background item 4). Detected by `source_session_id ~= self.session_id` or `self.agent:subagent_task_id(update)` non-nil. The transcript shows it with the main agent's code, so main and subagent show the same item in the same place. The shared code is `notes/PLAN-agent-view-consolidation.md`; this step needs only the routing, and the display follows that plan:

     | Item | Main agent today | Subagent | Shared code |
     |---|---|---|---|
     | Model | Body line `Loaded <name> · <id>` (`announce_model_loaded`, `session_manager.lua:2756`); notice on a switch (`_notice_model_switched`, `:2781`). Not in the header (`:2650`). | Same line in the transcript body when the model is first known; notice when it changes. | Both functions take the writer and the last announced id, in place of `self.message_writer` and `self._announced_model_id`. |
     | Mode | Header context, only when not the default (`_update_chat_header`, `:2653-2662`). | Open: `PLAN-agent-view-consolidation.md` Open question 2. | `AgentView:mode_label()`. |
     | Thought level | Not shown yet: `notes/feature-thought-level-display.md`. | As for the main agent. | That feature's code. |
     | Todo list | `plan` → the todos panel (`:1357-1360`), one panel per widget. | A TodoWrite list is the subagent's own (Claude Code keys it by agent id), so it gets its own todos panel with the subagent's windows. The Task* list is one list per session, so it stays in the main panel. | `TodoList`. |

     The main header's file count, token count and budget have no subagent equivalent: the subagent code sends no `usage_update`.
3. **`message_writer.lua` / `tool_call_renderer.lua`**: add `ToolCallBase.reply? string[]`. The writer merges it like `body` (divider between delegations, `:2841-2850`). The renderer (`:1356-1380`) writes it for `SubAgent` blocks as a second `markdown` fence after the prompt fence. That fence is **not folded and not dimmed**, because the report is what the user reads. The prompt fence keeps `fold_state = "closed"`. Writes go through `update_tool_call_block`, which already calls `_schedule_follow` and `_own_edit` (`:2911-2913`), so the follow rule holds without a new write method.
4. **`chat_history.lua`**: no schema change. `reply` persists on the block's tool_call message through `update_tool_call`. Path B (`prepend_restored_messages`) adds the reply to the SubAgent tool call's `Result:` text.
5. **`doc/agentic.txt`**:
   - Bump the pin to 0.95.0 (`:78-81`).
   - In `agentic-subagents`, the block gets a "Reply" row. A resumed agent continues in the same transcript.
   - Drop the generation wording.
6. **`provider-system` skill** § Subagents are child sessions: name the RFD updates in place of `subagent_spawned`/`subagent_state_update`.

### Step 2 (later)
- Unlinked incoming messages (resume prompt, SendMessage delivery) as a `##` row in the recipient's transcript. Needs a new `MessageWriter:write_incoming_message(lines)` that calls `_schedule_follow` and writes in `_own_edit` (follow skill), and a history message type that `SessionRestore.replay_messages` renders.
- A repeated `messageId` on the same session updates the message already shown (upsert).
- `capabilities.cancel`: `<C-c>` in a transcript sends `session/cancel {sessionId = child}` in place of the TaskStop relay. This reopens §4 of `notes/feature-scoped-cancel-subagents.md`, which was closed on 0.75.1.
- `requires_action` in the block footer. The child's model also in the block heading in the main chat.
- Nested children's blocks in the parent's transcript in place of the main chat.
- Delete the AIR-only `ClaudeUtils.agent_id` generation parsing, `_show_generation` and `_latest_generation` once no saved session needs them. Saved sessions hold `:generation:N` ids, so keep them in step 1.

## Tests
Fixtures are copied from the bridge shapes cited in Background.
- `acp_client.test.lua:1060`:
  - `spawn` sends the announce `subagent_update`. The existing routing tests then pass unchanged.
  - New: a nested announce (child of a child) routes to the root.
  - New: a child's `session/request_permission` reaches `on_request_permission` and is not auto-cancelled.
- `tests/integration/test_native_subagents.lua`:
  - SETUP `spawn` sends the announce and then both prompt views. `state` takes a `StateUpdate`, e.g. `{ state = "idle", stopReason = "end_turn" }`. The existing cases keep their intent.
  - New: both prompt views give one block body.
  - New: `launchReply` fills the reply. A hand-back pair gives one reply.
  - New: `idle` then `running` reopens the same transcript and input.
  - New: a child's `config_option_update`, on the child session and on the root with `parentToolUseId`, leaves the main agent's config options unchanged and announces the model in the transcript.
  - The load section (:348-357) uses the `RfdSubagentReplay` order: announce, prompt pair, child traffic, reply, final state.
- `test_subagent_inputs.lua:40-48`, `test_goto_file.lua:174`, `test_buffer_lifecycle.lua:446`: switch the fixtures to the new shapes.
- `make validate`.

## Expected outcome
- With bridge 0.95.0:
  - Subagents have blocks and live transcripts again.
  - Their permission prompts work.
  - The chat shows each launch prompt (folded) and each answer or hand-back report (open) once, in the subagent's block.
  - The main agent's config options and header hold only the main agent's values.
  - A subagent's transcript shows its model and mode as the main chat shows the main agent's.
  - A resumed subagent continues in its transcript.

## Non-goals
- The AIR form and bridges older than the RFD form: after the pin bump, the plugin supports one form.
- ACP v2 (`state_update` on the child stream).
- `session_message_chunk`: the v1 bridge never sends it. It falls to the unknown-type notice.
- Updating the global `acp` skill's `references/claude-agent.md` § Native subagent sessions, which still describes the AIR form as current. That belongs in a separate edit of that skill.

## Open questions
1. **Presenting a subagent (design decision for the user).** How a subagent block and its transcript show the subagent's state (the bridge reports `running`, `requires_action`, `idle` with an optional `stopReason`, `unknown`; today `_close_agent` maps these to tool-call statuses, `session_manager.lua:968-973`, and stamps unfinished calls `cancelled`, `:1076-1079`).
2. **Background reports.** A background child's report lands in its block, which can be far up the chat. Is that enough? The alternative is to also write a one-line pointer at the stream tail (a `write_notice` breadcrumb that names the block) and raise `[idle]` attention.
