# Plan: a nested subagent's block in its parent's transcript
Status: reviewed spec

f87761d (landed) moved the subagent code named here from SessionManager to `Subagents` (`lua/agentic/subagents.lua`); rename before implementing. `_on_subagent_update` → `update`, `_add_history_transcripts` → `add_history_transcripts`, `_transcript_for` → `transcript`, `_read_agent_record` → `read_record`, `_agent_key` → `agent_key`; `self._agents` and `_agent_by_task` are `Subagents` fields; `_write_row` keeps only the transcript half, the chat half is `SessionManager:_write_chat_row`. `_open_agent` takes a `replayed` flag instead of reading `_loading`.

## Relevant files
- `lua/agentic/session_manager.lua`: `_open_agent`, `_agent_block`, `_set_agent_info`, `_write_row`, `_on_subagent_update` (`parent_session_id`); `_render_history`, `_writer_for`; callers of `_agent_block` that the wider search reaches: `_add_history_transcripts` (rewrites the block's `argument`), `_replay_transcript`, `_transcript_for`, `_read_agent_record`, `_on_subagent_update`, `_open_input`, `_agent_label`, `_confirmed_blocking`
- `lua/agentic/ui/chat_history.lua`: `_list_for`, `update_tool_call` (already searches `subagent_messages`), `prepend_history_messages`
- `lua/agentic/ui/subagent_transcript.lua`: `_is_loaded`
- `lua/agentic/session_resume.lua`: `replay_messages` (renders a stored `tool_call` as a block)
- Tests: `lua/agentic/ui/chat_history.test.lua`, `tests/integration/test_native_subagents.lua`
- `doc/agentic.txt` § `agentic-subagents`
- Skills: `rendering`, `follow`, `session-lifecycle`

## Background
A subagent can launch its own subagent. The bridge announces the child on its parent's session (`subagent_update` with `source_session_id` = the parent), and `_open_agent` records it as `agent.parent_session_id` (`_on_subagent_update` fills it in for an agent restored from a file). But `_open_agent` always writes the launch block into the main chat and `chat_history.messages`, so a nested launch shows in the main chat, away from the transcript of the agent that made it.

A child's stored messages are keyed by `_agent_key(child_id)` in `subagent_messages`, and `replay_messages` already renders a stored `tool_call` as a block. So a block stored under the parent's key renders in the parent's transcript on reload, with no new storage.

## Changes
1. `chat_history.lua`: one search for a tool call record, which `update_tool_call` then uses.
   ```lua
   --- The record of a tool call, in the main chat's messages or a subagent's.
   --- @param tool_call_id string
   --- @return agentic.ui.ChatHistory.ToolCall|nil
   function ChatHistory:tool_call(tool_call_id)
   ```
2. `subagent_transcript.lua`: make `_is_loaded` public as `is_loaded()`; its callers in the file follow.
3. `session_manager.lua`
   - Extract from `_write_row` the two branches on `self._agents[session_id]`:
     ```lua
     --- The writer and working indicator of a session's buffer: a subagent's
     --- transcript, else the chat. Gets a subagent's transcript first, since
     --- reloading it replays the history; so it remakes a wiped transcript
     --- and loads an unloaded one.
     --- @param session_id string
     --- @return agentic.ui.MessageWriter writer
     --- @return agentic.ui.StatusIndicator indicator
     function SessionManager:_view_of(session_id)

     --- The key a session's history messages are stored under: the subagent's
     --- `_agent_key`, nil for the chat.
     --- @param session_id string
     --- @return string|nil
     function SessionManager:_history_key(session_id)
     ```
     `_write_row` uses both and keeps its `mid_turn` logic.
   - `_open_agent(child_id, label, parent_session_id)`: the owner is `parent_session_id` when `self._agents[parent_session_id]` exists, else the chat. The record gets `agent_key = self:_history_key(owner)`, so `add_message` stores a nested block in `subagent_messages`.
     - Write the block through `_view_of(owner)`, then `indicator:reposition()`, so a working parent's indicator stays below it; then add the record. Same order as `_write_row`. No `_loading` branch:
       - A load without a file (or without `loadSession`) replays the owner's earlier tool calls through `_writer_for`, which loads the owner's transcript. A block written only to the history would miss that loaded transcript.
       - A load from a file calls `_open_agent` only for an agent the file does not hold: `_render_history` runs `_add_history_transcripts` first, which gives every agent in `chat_history.subagents` an `_agents` entry.
     - Docstring: "its block in its parent's view, the main chat for a child of the main agent".
   - `_agent_block(child_id)`: `self.chat_history:tool_call(child_id)`. Docstring: "The block of a subagent in its parent's view, as the history holds it."
   - `_set_agent_info(child_id, subagent)`: always update the history record. Update the live block only in the view the record names: its `agent_key` nil means the chat; else the agent `_agent_by_task[key]` or the agent `key`, and only when that agent's transcript exists and `is_loaded()` (an unloaded one renders from the history; a wiped one is not remade). This does not read `parent_session_id`, which `_on_subagent_update` sets after its relabel and `_add_history_transcripts` leaves nil.
4. `doc/agentic.txt` § `agentic-subagents`: a subagent launched by another subagent shows its block in that subagent's transcript.

## Tests
- `lua/agentic/ui/chat_history.test.lua`: `tool_call` finds a record in either list.
- `test_native_subagents.lua`:
  - A grandchild announced on `c1`'s session writes its block in `c1`'s transcript, not in the chat; its history record is in `subagent_messages` under `c1`'s key; `c1`'s indicator stays below it.
  - `gf` on that block opens the grandchild's transcript.
  - A relabel (`title` on the grandchild) updates the block in `c1`'s transcript; while `c1`'s transcript is wiped, it updates the history and does not remake the transcript.
  - Wiping `c1`'s transcript and reopening it shows the block once.
  - A load whose file holds the nested block shows it once in `c1`'s transcript, adds no history message and leaves `c1`'s transcript unloaded.
  - A load without a file, whose replay announces `c1`, runs a tool call in `c1`, then announces the grandchild, shows the block once in `c1`'s transcript and not in the chat.
  - A re-create from history (`replace_with_history`) rewrites the nested block's `argument`, so `gf` opens the new transcript.
- `make validate`.

## Expected outcome
- The main chat shows only the main agent's own subagent launches. A nested launch shows in the transcript of the subagent that made it, live and after a reload, a load or a re-create from history.
- The history a re-created session sends (`prepend_history_messages`, which reads only the main messages) no longer names nested launches.

## Non-goals
- Moving nested blocks that a session file saved before this change holds in the main messages: a resume of such a file shows them in the chat.

## Open questions
None.
