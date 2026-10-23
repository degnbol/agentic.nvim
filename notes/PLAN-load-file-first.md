# Plan: render a loaded session from its file, and add only the replay's new tail
Status: spec

Requires:
- Commit 3f444ae: `read_saved_session(session_id)` in `session_manager.lua` (`ChatHistory.find_files(id)[1]` then `FileSystem.read_json`) and `ChatHistory.from_data`. The steps below still name the earlier `find_file`/`read`.
- `notes/PLAN-restore-picker.md` and `notes/PLAN-unify-history-restore.md`. In the unify plan, `restore_from_history` calls `clear_chat` before it replays. The `session/load` error branch needs that, because with this plan the chat is already rendered when the error arrives.

Fixes `notes/bug-load-save-drops-file-only-content.md`.

## Relevant files
- `lua/agentic/session_manager.lua` and `.test.lua`:
  - `_do_load_acp_session` and its `session/load` callback (both branches);
  - `_build_handlers`;
  - the `_loading` subagent gates in `_on_session_update` (`agent_message_chunk`, `agent_thought_chunk`), `_on_tool_call` and `_on_tool_call_update`;
  - the `user_message_chunk` branch;
  - `_send_synthetic_prompt`, `_refresh`, `_cancel_session`, `_advance_session_epoch`, `_restore_transcripts`, `_history_changed`, `restore_from_history`, `_adopt_history`;
  - tests "keeps the saved deciders for the replayed tool calls" and "drops held deciders once the load has …"
- `lua/agentic/utils/prompt_blocks.lua`
- `lua/agentic/acp/acp_client.lua` (`load_session`) and the Claude adapter `claude_agent_acp_adapter.lua`
- `lua/agentic/ui/chat_history.lua` — `UserMessage`, `prepend_restored_messages`
- `lua/agentic/session_restore.lua` — `replay_messages`, `format_preview`
- `lua/agentic/ui/tool_call_diff.lua` — `vim.text.diff` usage
- `tests/integration/test_session_load.lua` — mock-transport harness
- Skills: `session-lifecycle`, `provider-system`

## Background
`_do_load_acp_session` rebuilds the history from the provider's `session/load` replay, and the first save after it overwrites the file. A comparison of real sessions, file against replay (claude-agent-acp 0.85.1), found that the replay:
- **drops** some hidden commands (`/compact`), bridge-synthetic tool calls (compaction, plan-file clear), `Agent` launch calls, `cancelled` statuses, the live subagent block id and its `subagent` info, and every timestamp;
- **adds** user rows that were never shown live: the compaction summary, `[Request interrupted by user]` markers and the transient-retry `continue` prompt;
- **reorders** a prompt sent while output was streaming, to after the agent text or tool call that followed it;
- **changes** some tool call bodies (an empty Bash result becomes `(Bash completed with no output)`).

The file is the plugin's own record, and the replay is a lossy copy. The replay is still needed for two things:
- it restores the provider's state;
- it is the only source for turns made outside the plugin. `claude --resume <id>` appends to the same transcript, so a later load replays those turns.

So the file renders the conversation, and the replay adds only what comes after the file's end. A rule applied to the stream as it arrives cannot find that end reliably. The plan holds the replay's conversation updates until the load completes, and then aligns the whole replay with the file.

**Alignment.** Both sides become sequences of entries:
- a main-chat tool call has the key `tool:<id>`;
- a main-session prompt has the key `prompt:<text>`;
- agent and thought rows have no key.

The longest common subsequence of the keys (`vim.text.diff` with `result_type = "indices"`, one key per line) tolerates rows that only one side has, in any position. A replayed entry is **new** when its key has occurred more often in the replay so far than in the whole file. This rule matches a reordered prompt by its count, and it lets repeated prompt texts match in order. The tail starts after the last matched entry:
- if the file has no rows after its last matched entry, it starts at the entry right after that match. This is a turn cut off in the file and continued elsewhere.
- otherwise it starts at the first new entry that is a tool call or a turn-starting prompt. The file's own closing agent text after the match then never starts a tail.

In a simulation over 234 local sessions, the start-at-first-new-entry rule found 10 tails, where a rule that needs a new prompt found 3. Over 104 files cut after a reordered prompt, the count rule cut the false tails from 14 to 1.

## Changes
1. `prompt_blocks.lua`: move the XML-tag and `IMPORTANT: Focus` test out of the `user_message_chunk` branch, which then calls it.
   ```lua
   --- Whether a user content block is prompt text, not a block the plugin or the
   --- provider adds to a prompt (`<tag>…</tag>` metadata, the selection focus).
   --- @param text string
   --- @return boolean
   function PromptBlocks.is_prompt_text(text)
   ```
2. New `lua/agentic/session_replay_align.lua`. It is pure: it has no SessionManager dependency.
   ```lua
   --- One conversation row, reduced to what alignment needs.
   --- @class agentic.ReplayAlign.Entry
   --- @field key? string `tool:<id>` for a main-chat tool call, `prompt:<text>` for a main-session prompt, nil for other rows
   --- @field starts_turn boolean A main-session prompt that the user sent

   --- One entry per main-chat message of a session file, in order.
   --- @param messages agentic.ui.ChatHistory.Message[]
   --- @return agentic.ReplayAlign.Entry[]
   function M.file_entries(messages)

   --- Index of the first replayed entry that the file does not hold.
   --- @param file agentic.ReplayAlign.Entry[]
   --- @param replay agentic.ReplayAlign.Entry[]
   --- @return integer|nil start `#replay + 1` when there is no tail; nil when both sides have keys and none match
   function M.tail_start(file, replay)
   ```
   - The rules are in § Background.
   - Edge cases of `tail_start`:
     - With no match, and a replay whose first entry is a replay-only prompt (a compaction done outside the plugin), the tail is the first turn-starting prompt after it.
     - When the file has keys and the replay has none, it returns `#replay + 1`.
   - `file_entries` makes a synthetic user row (change 4) a keyed prompt that does not start a turn.
3. `acp_client.lua`: add
   ```lua
   --- Whether a replayed prompt is one the provider adds itself during a
   --- session/load replay, not one the user sent.
   --- @param _text string
   --- @return boolean
   function ACPClient:is_replay_only_prompt(_text) return false end
   ```
   The Claude adapter returns true for text that starts with `This session is being continued from a previous conversation` (the compaction summary) or `[Request interrupted by user`.
4. Synthetic prompts. `ChatHistory.UserMessage` gets `--- @field synthetic? boolean Sent by the plugin, not typed`. `_send_synthetic_prompt` adds a user message with `synthetic = true`. `replay_messages`, `format_preview` and `prepend_restored_messages` skip it. The transient-retry `continue` then has a file key, so it cannot start a false tail.
5. `session_manager.lua`
   - Split the restore steps so that unify's `restore_from_history` and the load path share them:
     ```lua
     --- Make `history` the session's: the history, its modified flag, file
     --- tally and title.
     --- @param history agentic.ui.ChatHistory
     function SessionManager:_install_history(history)

     --- Render `self.chat_history`: the subagent transcripts, then the messages.
     function SessionManager:_render_history()
     ```
     - `_install_history`: `self.chat_history = history`, `_sync_modified`, `file_activity:clear()` and `load`, the title and `_title_user_set`. Unify's `restore_from_history` body calls it.
     - `_render_history`: `_restore_transcripts`, `SessionRestore.replay_messages`, `status_indicator:reposition()`. Unify's `on_created` calls it.
     - Neither function sets `_history_to_send`. The provider already holds a loaded conversation.
   - Field `--- @field _replay_hold? { kind: string, args: table }[] Conversation updates of a session/load replay, held until the load completes`. It is set only while `_loading`. Every site that clears `_loading` also clears it: the callback, `_refresh` and `_cancel_session`.
   - `_build_handlers`: while `_replay_hold` is set, `on_session_update`, `on_tool_call` and `on_tool_call_update` append conversation updates to it and return. Conversation updates are `tool_call`, `tool_call_update`, `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`, `subagent_spawned` and `subagent_state_update`. Other session updates (commands, modes, config options, usage, plan) are applied at once, because they are provider state.
   - Add
     ```lua
     --- The alignment entry of one held replay update.
     --- @param held { kind: string, args: table }
     --- @return agentic.ReplayAlign.Entry
     function SessionManager:_replay_entry(held)
     ```
     - It is main-session only when `source_session_id == self.session_id` and `agent:subagent_task_id(update)` is nil. It does not use `_agents`, because no held `subagent_spawned` has been dispatched yet.
     - A prompt starts a turn when `PromptBlocks.is_prompt_text` is true and `agent:is_replay_only_prompt` is false.
   - `_do_load_acp_session`:
     - Capture the epoch after `_advance_session_epoch`. The callback returns at once when `_session_epoch` has moved on, for example after `/new`.
     - `local path = ChatHistory.find_file(session_id); local saved_history = path and ChatHistory.read(path)`.
     - When `saved_history` exists and `agent_capabilities.loadSession` is true: call `_install_history(saved_history)` and `_render_history()` before `load_session` is sent, then set `_replay_hold = {}`. The file's `timestamp` stays as it is. Delete the `stash_deciders` loop, because the rendered tool calls carry `decided_by`.
     - Without `loadSession`: no render and no hold. `ACPClient:load_session` calls back with an error, and the fallback renders once.
     - Without a file: no hold. The replay renders as today.
   - `session/load` callback, success, in this order:
     1. Take the hold and clear `_replay_hold`.
     2. `local start = SessionReplayAlign.tail_start(SessionReplayAlign.file_entries(self.chat_history.messages), entries)`, with the entries from `_replay_entry`. When `start` is nil, notify once with `Logger.notify` (WARN) that the replay could not be matched to the session file, and dispatch nothing.
     3. Dispatch the held updates from `start` on through the same handlers, with `_loading` still true. `_try_record_edit_range` then skips replayed edits.
     4. Set `_restoring` and `_loading` to false.
     5. `status_indicator:stop()` and `_sync_modified`.
     6. Apply the config options and `set_pending_initial_model`.
     7. `_history_changed` only when `chat_history.dirty`. A load without a tail writes nothing. The model saved here can be the one from before `set_pending_initial_model` takes effect. The next turn's save corrects it.
     8. The RESUME notice.
     9. `_dispatch_deferred_prompts`.

     Delete `chat_history.dirty = false` and `drop_deciders`. Run `_restore_transcripts` only on the no-file path.
   - `session/load` callback, error: delete the `drop_deciders` call, and pass `self.chat_history` to `_fallback_restore_from_local`.
   - `_refresh` clears the hold. Updates that arrive after it render live below the file. That is accepted, because `_refresh` is the manual escape from a stuck load.
   - Delete the four `_loading` subagent gates. With the hold, the updates that the file covers never reach them, so tail subagents take the live path. On a load without a file, replayed subagent output is now recorded too. That is intended, because the replay is the only source there.
6. `session-lifecycle` skill: in the `session/load` section, say that the file renders the chat and the replay adds only the aligned tail.
7. Delete `notes/bug-load-save-drops-file-only-content.md`.
8. Tests
   - `session_replay_align.test.lua`, `tail_start`:
     - the same turns on both sides: no tail;
     - a new prompt-led turn after the file's end;
     - prompts and text-only turns after the file's last tool call: no tail;
     - a turn cut off in the file and continued elsewhere: the tail starts after the last match, keyed rows included;
     - a turn the provider ran without a replayed prompt (new tool calls, no new prompt);
     - file rows that the replay never sends (SubAgent ids, `Agent` launch calls, synthetic ids, hidden commands) do not break the match;
     - replay-only prompts after the last match do not start a tail;
     - a prompt moved past a tool call at the end of the file: no tail;
     - repeated prompt texts match by count;
     - a synthetic `continue` in the file matches the replayed one;
     - a compaction outside the plugin: the tail starts after the summary;
     - nil when both sides have keys and none match; `#replay + 1` when the replay has no keys.
   - `prompt_blocks.test.lua`: `is_prompt_text`.
   - `session_manager.test.lua`:
     - replace "keeps the saved deciders for the replayed tool calls" with "the rendered tool calls carry `decided_by` from the file";
     - delete "drops held deciders once the load has …";
     - while loading with a file, a conversation update is held and an `available_commands_update` is applied;
     - `_replay_entry`: a child prompt is not main, even with no `_agents` entry;
     - `/new` during a load: the stale callback does nothing; `_refresh` clears the hold;
     - without `loadSession`, nothing renders before the fallback, and no hold is set;
     - `_send_synthetic_prompt` records a synthetic user row, which `replay_messages` skips.
   - `tests/integration/test_session_load.lua`. Set `Config.session_restore.storage_path = vim.fn.tempname()`, write a session file there, and use the real `ChatHistory.read`. Then replay the same turns plus one new turn:
     - the chat shows the file's rows once, then the new turn;
     - `chat_history.timestamp` is the file's;
     - a hidden-command row and a `cancelled` tool call survive the load and one save;
     - after the load the indicator is stopped, the file holds the tail, and no pending edit range was recorded;
     - a second load of the saved file adds nothing;
     - a load without a tail does not write the file;
     - an error after the render shows the chat once;
     - a tail subagent's output is in its transcript and in `subagent_messages`.
   - `acp_client.test.lua` and the adapter test: `is_replay_only_prompt`.

## Expected outcome
- A loaded session shows what the plugin rendered live: hidden commands, cancelled calls, subagent blocks with their transcripts, and prompts in the order they were sent.
- The session file keeps its timestamps and everything else it held. A load without new turns does not write it.
- Turns added outside the plugin show after the file's content and are saved, subagent output included. This includes `claude --resume`, a turn cut off in the file, and a compaction made there.
- If the replay cannot be matched to the file, the file wins and a warning says so.

## Non-goals
- Opening a session that has no plugin file (started in `claude`). That needs a session list from the transcripts or from ACP `session/list`.
- Replay quirks inside the tail: replay subagent ids (`notes/bug-replayed-subagent-empty-transcript.md`), changed bodies, load-time timestamps.

## Open questions
None.
