# Plan: load from file first
Status: reviewed spec

Requires:
- `1d6432e` (landed): `restore_from_history` calls `clear_chat` before it replays. The `session/load` error branch needs that, because with this plan the chat is already rendered when the error arrives. It added `ChatHistory.read_saved(session_id)`, the one reader of a saved session file, and the epoch guard of the `session/load` callback.
- Main-chat `session_message` rows carry `message_id`, which alignment keys on (landed in `ed91fb6`).

Fixes `notes/bug-load-save-drops-file-only-content.md`.

## Relevant files
- `lua/agentic/session_manager.lua` and `.test.lua`:
  - `_do_load_acp_session` and its `session/load` callback (both branches);
  - `_build_handlers`;
  - the `_loading` subagent gates in `_on_agent_chunk`, `_on_tool_call` and `_on_tool_call_update`, and the `_loading` checks in `_on_subagent_update` and `_on_session_message`. The check in `_open_agent` (unload a transcript opened while loading) and the main chat's `mid_turn` in `_write_row` stay;
  - the `user_message_chunk` branch;
  - `_send_synthetic_prompt`, `_refresh`, `_cancel_session`, `_advance_session_epoch`, `_restore_transcripts`, `_history_changed`, `restore_from_history`, `new_session` (its `history` option);
  - tests "keeps the saved deciders for the replayed tool calls" and "drops held deciders once the load has …"
- `lua/agentic/acp/acp_payloads.lua` (builds the selection and metadata blocks that `is_prompt_text` recognises)
- `lua/agentic/acp/acp_client.lua` (`load_session`, `subagent_task_id`) and the Claude adapter `claude_agent_acp_adapter.lua`
- `lua/agentic/ui/chat_history.lua`: `UserMessage`, `prepend_restored_messages`, `read_sessions_from_folder` (`prompt_count`)
- `lua/agentic/session_restore.lua`: `replay_messages`, `format_preview`
- `lua/agentic/ui/tool_call_diff.lua`: `vim.text.diff` usage
- `tests/integration/test_session_load.lua`: mock-transport harness
- `tests/integration/test_native_subagents.lua`: "subagents on load and restore", and "a tool call update while loading leaves the transcript unloaded"
- Skills: `session-lifecycle`, `provider-system`

## Background
`_do_load_acp_session` rebuilds the history from the provider's `session/load` replay, and the first save after it overwrites the file. A comparison of real sessions, file against replay (claude-agent-acp 0.85.1), found that the replay:
- **drops** some hidden commands (`/compact`), bridge-synthetic tool calls (compaction, plan-file clear), `Agent` launch calls, `cancelled` statuses, the live subagent block id and its `subagent` info, and every timestamp;
- **adds** user rows that were never shown live: the compaction summary, `[Request interrupted by user]` markers and the transient-retry `continue` prompt;
- **reorders** a prompt sent while output was streaming, to after the agent text or tool call that followed it;
- **changes** some tool call bodies (an empty Bash result becomes `(Bash completed with no output)`).

The loss is in the bridge's replay; this plan designs around it in the client.

The file is the plugin's own record, and the replay is a lossy copy. The replay is still needed for two things:
- it restores the provider's state;
- it is the only source for turns made outside the plugin. `claude --resume <id>` appends to the same transcript, so a later load replays those turns.

So the file renders the conversation, and the replay adds only what comes after the file's end. A rule applied to the stream as it arrives cannot find that end reliably. The plan holds the replay's conversation updates until the load completes, and then aligns the whole replay with the file.

**Alignment.** Both sides become sequences of entries:
- a main-chat tool call has the key `tool:<id>`;
- a main-session prompt has the key `prompt:<text>`. A user chunk that is not prompt text (`ACPPayloads.is_prompt_text` false: `<tag>…</tag>` metadata, the selection focus) has no key;
- a main-chat message row (a stored `session_message`, a replayed `session_message` view on the root) has the key `message:<message_id>`;
- agent and thought rows, subagent output and `subagent_update` have no key;
- a `tool_call_update` gets no entry at all. It is not a row: it changes one.

Keys are mapped to integer ids, one per distinct key, and the two id lists go to the longest common subsequence (`vim.text.diff` with `result_type = "indices"`, one id per line). Entries without a key are left out of the diff input and mapped back by index. The LCS tolerates rows that only one side has, in any position. A replayed entry is **new** when its key has occurred more often in the replay so far than in the whole file. This rule matches a reordered prompt by its count, and it lets repeated prompt texts match in order. The tail starts after the last matched entry:
- if the file has no rows after its last matched entry, it starts at the entry right after that match. This is a turn cut off in the file and continued elsewhere.
- otherwise it starts at the first new entry that is a tool call, a turn-starting prompt or a message row. The file's own closing agent text after the match then never starts a tail.

The start-at-first-new-entry rule finds tails that start with a tool call and no new prompt (a turn the provider ran by itself); the count rule keeps a reordered prompt from reading as new.

## Changes
1. `acp_payloads.lua`: move the XML-tag and `IMPORTANT: Focus` test out of the `user_message_chunk` branch, which then calls it.
   ```lua
   --- Whether a user content block is prompt text, not a block the plugin or the
   --- provider adds to a prompt (`<tag>…</tag>` metadata, the selection focus).
   --- @param text string
   --- @return boolean
   function M.is_prompt_text(text)
   ```
2. New `lua/agentic/utils/sequence_tail.lua`. Generic: it knows keys and turn starts, not ACP or history.
   ```lua
   --- One row of a keyed sequence.
   --- @class agentic.utils.SequenceTail.Entry
   --- @field key? string Rows with equal keys are the same row; nil for a row that never matches
   --- @field starts boolean Whether a tail may start at this row

   --- Index of the first entry of `replay` that `file` does not hold.
   --- @param file agentic.utils.SequenceTail.Entry[]
   --- @param replay agentic.utils.SequenceTail.Entry[]
   --- @return integer|nil start `#replay + 1` when there is no tail; nil when both sides have keys and none match
   function M.tail_start(file, replay)
   ```
   - The rules are in § Background.
   - Edge cases:
     - With no match, and a replay whose first keyed entry does not start a tail (a replay-only prompt: a compaction done outside the plugin), the tail is the first entry after it that starts one.
     - When the file has keys and the replay has none, it returns `#replay + 1`.
3. `chat_history.lua`:
   ```lua
   --- One alignment entry per main-chat message, in order.
   --- @return agentic.utils.SequenceTail.Entry[]
   function ChatHistory:sequence_entries()
   ```
   A synthetic user row (change 5) is a keyed prompt with `starts = false`. `read_sessions_from_folder` does not count a synthetic row in `prompt_count`.
4. `acp_client.lua`: add
   ```lua
   --- Whether a replayed prompt is one the provider adds itself during a
   --- session/load replay, not one the user sent.
   --- @param _text string
   --- @return boolean
   function ACPClient:is_replay_only_prompt(_text) return false end
   ```
   The Claude adapter returns true for text that starts with `This session is being continued from a previous conversation` (the compaction summary) or `[Request interrupted by user`.
5. Synthetic prompts. `ChatHistory.UserMessage` gets `--- @field synthetic? boolean Sent by the plugin, not typed`. `_send_synthetic_prompt` adds a user message with `synthetic = true`; its docstring drops "no `chat_history` entry" and says the row is recorded as synthetic, which `replay_messages`, `format_preview`, `prepend_restored_messages` and `prompt_count` skip, so a re-create from history (Path B) still reads the response as one continuous turn. The transient-retry `continue` then has a file key, so it cannot start a false tail.
6. `session_manager.lua`
   - Split the history steps so that `restore_from_history` and the load path share them:
     ```lua
     --- Make `history` the session's: the history, its modified flag, file
     --- tally and title.
     --- @param history agentic.ui.ChatHistory
     function SessionManager:_install_history(history)

     --- Render `self.chat_history`: the subagent transcripts, then the messages.
     function SessionManager:_render_history()
     ```
     - `_install_history`: `self.chat_history = history`, `_sync_modified`, `file_activity:clear()` and `load`, the title and `_title_user_set`. In `restore_from_history`, the history assignment, file tally and title become this call.
     - `_render_history`: `_restore_transcripts`, `SessionRestore.replay_messages`, `status_indicator:reposition()`. `restore_from_history`'s `on_created` calls it.
     - Neither function sets `_history_to_send`. The provider already holds a loaded conversation.
     - `new_session({ history })` does not call `_install_history`. Its callback runs on a history already installed (by `restore_from_history`) or already the session's own (`switch_provider`, respawn), and only re-ids it and queues it for sending; a second install would only clear and reload the same file tally and title.
   - Field `--- @field _replay_hold? { kind: string, args: table }[] Conversation updates of a session/load replay, held until the load completes`. It is set only while `_loading`. Every site that clears `_loading` also clears it: the callback, `_refresh` and `_cancel_session`.
   - Field `--- @field _replay_dropped? boolean Set by `_refresh` during a hold: replay updates are dropped until the load callback`. Cleared by the callback and `_cancel_session`.
   - `_build_handlers`: while `_replay_hold` is set, `on_session_update`, `on_tool_call` and `on_tool_call_update` append conversation updates to it with their full arguments, including the `source_session_id` that `ACPClient:__with_subscriber` passes to every handler, and return. While `_replay_dropped` is set they drop conversation updates. Conversation updates are `tool_call`, `tool_call_update`, `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`, `subagent_update` and `session_message`. Other session updates (commands, modes, config options, usage, plan) are applied at once, because they are provider state.
   - Add
     ```lua
     --- The alignment entry of one held replay update; nil for a
     --- `tool_call_update`, which is no row.
     --- @param held { kind: string, args: table }
     --- @return agentic.utils.SequenceTail.Entry|nil
     function SessionManager:_replay_entry(held)
     ```
     - A held update is main-session only when its `source_session_id == self.session_id` and it has no subagent tag: `parent_tool_use_id` on a held `tool_call` (an adapter-built `ToolCallBlock`), `agent:subagent_task_id(update)` on a raw session update. It does not use `_agents`, because no held `subagent_update` has been dispatched yet.
     - A prompt starts a tail when `ACPPayloads.is_prompt_text` is true and `agent:is_replay_only_prompt` is false; a chunk with `is_prompt_text` false gets no key.
   - `_do_load_acp_session`:
     - `saved_history` is `ChatHistory.read_saved(session_id)` through `ChatHistory.from_data`.
     - Capture `local from_file = saved_history ~= nil and agent_capabilities.loadSession`. The callback branches on it, not on `_replay_hold`, which `_refresh` clears.
     - With `from_file`: call `_install_history(saved_history)` and `_render_history()` before `load_session` is sent, then set `_replay_hold = {}`. This replaces the block that copies the title, file tally and subagents from the file. The loop that fills `_message_infos` and `_delegated` from the file's `session_message` rows stays, on every path with a file: replayed views and the tail reuse the file's kinds and delegations. The file's `session_id` and `timestamp` stay as they are; the `chat_history.session_id`/`timestamp = os.time()` stamping stays only on the other paths. Delete the `stash_deciders` loop, because the rendered tool calls carry `decided_by`.
     - With a file but no `loadSession`: no render and no hold. `ACPClient:load_session` calls back with an error, and the fallback renders once.
     - Without a file: no hold. The replay renders as today.
   - `session/load` callback, success, in this order:
     1. With `from_file`: take the hold and clear `_replay_hold`. If `_replay_dropped` is set, clear it and skip steps 2–3.
     2. `local start = SequenceTail.tail_start(self.chat_history:sequence_entries(), entries)`, with the entries from `_replay_entry` (updates left out, indices mapped back to the hold). When `start` is nil, notify once with `Logger.notify` (WARN) that the replay could not be matched to the session file, and dispatch nothing.
     3. Dispatch the held updates from `start` on through the same handlers, with `_loading` still true; `_try_record_edit_range` then skips replayed edits. A held `tool_call_update` before `start` is dropped; one at or after `start` is dispatched only when its `tool_call_id` was dispatched in the tail, so a block the file rendered is never changed.
     4. Set `_restoring` and `_loading` to false.
     5. `status_indicator:stop()` and `_sync_modified`.
     6. Apply the config options and `set_pending_initial_model`.
     7. `_history_changed` only when `chat_history.dirty`. A load without a tail writes nothing. On the no-file path the history is dirty, so the file is written at load end. The model saved here can be the one from before `set_pending_initial_model` takes effect. The next turn's save corrects it.
     8. The RESUME notice.
     9. `_dispatch_deferred_prompts`.

     Delete `chat_history.dirty = false` and `drop_deciders`. Without `from_file`, run `_restore_transcripts` as today.
   - `session/load` callback, error: delete the `drop_deciders` call, and keep passing `saved_history` to `_fallback_restore_from_local`. With `from_file` it is the same object as `self.chat_history`; without, `self.chat_history` is the empty history from `_reset_conversation`.
   - `_refresh` clears the hold and sets `_replay_dropped`, so the rest of the replay is dropped, not rendered below the file and saved as duplicates. `_refresh` is the manual escape from a stuck load; a later load adds what the dropped part held.
   - Delete the `_loading` subagent gates in `_on_agent_chunk`, `_on_tool_call` and `_on_tool_call_update`, the `_loading` return before the work state in `_on_subagent_update`, and the `_loading and not on_root` return in `_on_session_message`. With the hold, the updates that the file covers never reach them, so tail subagents take the live path: their output, message rows and starts and ends. On a load without a file, replayed subagent output, message rows and states are now recorded too. That is intended, because the replay is the only source there.
7. `session-lifecycle` skill: in the `session/load` section, say that the file renders the chat and the replay adds only the aligned tail.
8. Delete `notes/bug-load-save-drops-file-only-content.md`.
9. Tests
   - `sequence_tail.test.lua`, `tail_start`:
     - the same rows on both sides: no tail;
     - a new tail-starting row after the file's end;
     - unkeyed rows and non-starting keyed rows after the file's last match: no tail;
     - a sequence cut off in the file and continued: the tail starts after the last match, keyed rows included;
     - a new starting row with no new prompt before it;
     - file rows the replay never has do not break the match;
     - a row moved past another at the end of the file: no tail;
     - repeated keys match by count;
     - a replay whose first keyed row does not start: the tail starts at the next starting row;
     - nil when both sides have keys and none match; `#replay + 1` when the replay has no keys;
     - keys with newlines align as single rows.
   - `chat_history.test.lua`: `sequence_entries` (tool, prompt, synthetic, message rows; agent rows unkeyed); `prompt_count` skips a synthetic row.
   - `acp_payloads.test.lua`: `is_prompt_text`.
   - `session_manager.test.lua`:
     - replace "keeps the saved deciders for the replayed tool calls" with "the rendered tool calls carry `decided_by` from the file";
     - delete "drops held deciders once the load has …";
     - while loading with a file, a conversation update is held and an `available_commands_update` is applied;
     - `_replay_entry`: a child prompt is not main, even with no `_agents` entry; a held subagent `tool_call` is not main by its `parent_tool_use_id`; a `tool_call_update` has no entry; a metadata chunk has no key;
     - a held update of a call the file rendered leaves its block and history row unchanged;
     - `/new` during a load: the stale callback does nothing;
     - `_refresh` during a hold: later replay updates are dropped, and the callback dispatches nothing and saves nothing;
     - with a file but without `loadSession`: nothing renders before the fallback, no hold is set, and the fallback re-creates the session from the file's history;
     - `_send_synthetic_prompt` records a synthetic user row, which `replay_messages` skips.
   - `tests/integration/test_session_load.lua`. Its harness already sets `Config.session_restore.storage_path = vim.fn.tempname()`. Write a session file there with `ChatHistory:save`, so the load reads it through `ChatHistory.read_saved`. Then replay the same turns plus one new turn:
     - the chat shows the file's rows once, then the new turn;
     - `chat_history.timestamp` is the file's;
     - a hidden-command row and a `cancelled` tool call survive the load and one save;
     - after the load the indicator is stopped, the file holds the tail, and no pending edit range was recorded;
     - a second load of the saved file adds nothing;
     - a load without a tail does not write the file;
     - an error after the render shows the chat once;
     - a tail subagent's output, message rows and end are in its transcript and in `subagent_messages`.
   - `tests/integration/test_native_subagents.lua`, "subagents on load and restore" (its `before_each` saves a file, so every load there takes the file path):
     - keep "a state sent right behind the load response comes after the load", "nothing is modified or written while the load runs", "an end state sent again after the load writes nothing", "running sent after the load reopens the child", "a load takes the kinds and delegations from the file", "output saved without an agent record gets its own transcript" and "load then save keeps subagents";
     - rewrite "after a load the chat links the prompt, and gf loads the file's rows": the chat holds the file's rows once; the replayed reply, which the file lacks, is the tail (`message:toolu_1:reply`), and the transcript shows the file's rows, not the replayed chunk before the tail;
     - rewrite "a load whose replay sends the incoming view first writes one link": the message is new, so it is in the tail; the chat gets one link row and the transcript one body row;
   - Delete "a tool call update while loading leaves the transcript unloaded" (subagent edge cases): it tests a deleted gate, and with the hold such updates never reach the handlers.
   - `acp_client.test.lua` and the adapter test: `is_replay_only_prompt`.

## Expected outcome
- A loaded session shows what the plugin rendered live: hidden commands, cancelled calls, subagent blocks with their transcripts, and prompts in the order they were sent.
- The session file keeps its timestamps and everything else it held. A load without new turns does not write it.
- Turns added outside the plugin show after the file's content and are saved, subagent output and messages included. This includes `claude --resume`, a turn cut off in the file, and a compaction made there.
- If the replay cannot be matched to the file, the file wins and a warning says so.

## Non-goals
- Opening a session that has no plugin file (started in `claude`). That needs a session list from the transcripts or from ACP `session/list`.
- Replay quirks inside the tail: replay subagent ids (`notes/bug-replayed-subagent-empty-transcript.md`), changed bodies, load-time timestamps.

## Open questions
None.
