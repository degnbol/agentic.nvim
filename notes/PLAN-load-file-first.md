# Plan: render a loaded session from its file, and add only the replay's new tail
Status: spec

Requires:
- `notes/PLAN-history-session-cwd.md`: `ChatHistory.find_file(session_id)` and `ChatHistory.read(path)`.
- `notes/PLAN-restore-picker.md` and `notes/PLAN-unify-history-restore.md`. The restore-picker plan sends providers without `loadSession` straight to `_fallback_restore_from_local`. The unify plan's `restore_from_history` calls `clear_chat` before it replays. The `session/load` error branch needs that, because with this plan the chat is already rendered when the error arrives.

Fixes `notes/bug-load-save-drops-file-only-content.md`.

## Relevant files
- `lua/agentic/session_manager.lua` and `.test.lua`:
  - `_do_load_acp_session`: the reset block, the saved-history block (`stash_deciders` loop), the `loadSession` capability check from the restore-picker plan, and the `session/load` callback (both branches);
  - `_build_handlers`, `_on_session_update` (`user_message_chunk` branch, and the `_loading` gates in the `agent_message_chunk` and `agent_thought_chunk` branches), `_on_tool_call` and `_on_tool_call_update` (their `_loading` gates), `_open_agent`;
  - `_refresh`, `_cancel_session`, `_restore_transcripts`, `_history_changed`, `restore_from_history`
  - tests "keeps the saved deciders for the replayed tool calls" and "drops held deciders once the load has …"
- `lua/agentic/acp/acp_client.lua` and the Claude adapter `claude_agent_acp_adapter.lua`
- `lua/agentic/session_restore.lua` — `replay_messages`
- `lua/agentic/ui/permission_manager.lua` — `stash_deciders`, `drop_deciders`
- `lua/agentic/ui/status_indicator.lua`
- `tests/integration/test_session_load.lua` — mock-transport harness
- Skills: `session-lifecycle`, `provider-system`

## Background
`_do_load_acp_session` starts from an empty `ChatHistory` and rebuilds it from the provider's `session/load` replay. The first save after the load then overwrites the file. A comparison of three real sessions, file against replay (claude-agent-acp 0.85.1), found that the replay:
- **drops** hidden commands (`/compact`, `/model`, …), bridge-synthetic tool calls (compaction, plan-file clear), `Agent` launch calls, `cancelled` statuses, the live subagent block id and its `subagent` info, and every timestamp;
- **adds** user rows that were never shown live: the compaction summary, `[Request interrupted by user]` markers and auto-continue prompts;
- **moves** a prompt sent while output was streaming to after the agent text that followed it;
- **changes** some tool call bodies (an empty Bash result becomes `(Bash completed with no output)`).

The file is the plugin's own record and the replay is a lossy copy. The replay is still needed to restore the provider's state. It is also the only source for turns made outside the plugin: `claude --resume <id>` appends to the same transcript, so a later load replays those turns. So the file renders the conversation, and the replay adds only what comes after the file's end.

**Finding the file's end in the replay.** A streaming rule ("skip until the last tool call id, then start at the next prompt") failed on 2 of the 3 sessions:
- the file's last tool call was one that the replay never sends;
- the file had text-only turns after its last tool call.

So the plan holds the replay's conversation updates until the load completes and aligns the whole replay with the file. Both sides become sequences of keys: main-chat tool call ids and prompt texts. Their longest common subsequence tolerates rows that only one side has, in any position. The tail starts at the first replayed prompt after the last matched replay key. A provider-specific rule skips replay-only user rows when it looks for that prompt. Agent text has no key. The rest of the last file turn is already in the file, so it never starts a tail.

## Changes
1. New `lua/agentic/session_replay_align.lua`, pure, with no SessionManager dependency:
   ```lua
   --- One held replay update, reduced to what alignment needs.
   --- @class agentic.ReplayAlign.Entry
   --- @field key? string `tool:<id>` for a main-chat tool call, `prompt:<text>` for a main-session prompt, nil otherwise
   --- @field starts_turn boolean A main-session prompt that the provider did not add on its own during the replay

   --- Keys of a session file's main-chat messages, in order.
   --- @param messages agentic.ui.ChatHistory.Message[]
   --- @return string[]
   function M.file_keys(messages)

   --- Index of the first held entry that the file does not hold.
   --- @param file_keys string[]
   --- @param entries agentic.ReplayAlign.Entry[]
   --- @return integer|nil start `#entries + 1` when there is no tail; nil when both sides have keys and none match
   function M.tail_start(file_keys, entries)

   --- Whether a replayed user chunk is prompt text, not system metadata the
   --- provider replays as its own block.
   --- @param text string
   --- @return boolean
   function M.is_prompt_text(text)
   ```
   - `tail_start` uses the longest common subsequence of the file's keys and the entries' keys. The tail starts at the first entry with `starts_turn` after the last matched entry. With no match at all, it starts at the first entry with `starts_turn`, when the file has no keys.
   - `is_prompt_text` is the XML-tag and `IMPORTANT: Focus` test moved out of the `user_message_chunk` branch, which then calls it.
2. `acp_client.lua`: add
   ```lua
   --- Whether a replayed prompt is one the provider adds itself during a
   --- session/load replay, not one the user sent.
   --- @param _text string
   --- @return boolean
   function ACPClient:is_replay_only_prompt(_text) return false end
   ```
   Claude adapter override: true for text that starts with `This session is being continued from a previous conversation` (the compaction summary) or `[Request interrupted by user`.
3. `session_manager.lua`
   - Field: `--- @field _replay_hold? { kind: string, args: table }[] Conversation updates of a session/load replay, held until the load completes`.
   - Add a method that shows a history without sending it, shared with `restore_from_history`'s `on_created`. Nothing here sets `_history_to_send`, because the provider already holds this conversation.
     ```lua
     --- Make `history` the session's and render it: the history, its title,
     --- file tally and subagent transcripts, then its messages.
     --- @param history agentic.ui.ChatHistory
     function SessionManager:_show_history(history)
     ```
     Steps:
     1. `self.chat_history = history` and `_sync_modified`;
     2. `file_activity:clear()` and `load`;
     3. the title and `_title_user_set`;
     4. `_restore_transcripts`;
     5. `SessionRestore.replay_messages`;
     6. `status_indicator:reposition()`.
   - `_build_handlers`: while `_replay_hold` is set and `_loading` is true, `on_session_update`, `on_tool_call` and `on_tool_call_update` append conversation updates to `_replay_hold` and return. Conversation updates are `tool_call`, `tool_call_update`, `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`, `subagent_spawned` and `subagent_state_update`. Other session updates (commands, modes, config options, usage, plan) are applied at once, because they are provider state.
   - `_do_load_acp_session`, after the restore-picker capability check:
     - `local path = ChatHistory.find_file(session_id); local saved_history = path and ChatHistory.read(path)`.
     - With a file: `_show_history(saved_history)` before `load_session` is sent, then `_replay_hold = {}`. Keep the file's `timestamp`, and do not set it to `os.time()`. Delete the `stash_deciders` loop, because the rendered tool calls carry `decided_by` from the file.
     - Without a file: no hold. The replay renders as today.
     - Pass the fallback an untouched copy: `vim.deepcopy(saved_history)`, taken before `_show_history`.
   - `session/load` callback, success, with `_replay_hold` set:
     1. Take the hold and clear `_replay_hold`.
     2. Build an `Entry` for each held update. Use `is_prompt_text`, `agent:subagent_task_id`, the source session and `agent:is_replay_only_prompt` to tell main-session prompts and tool calls apart.
     3. `local start = SessionReplayAlign.tail_start(SessionReplayAlign.file_keys(self.chat_history.messages), entries)`.
     4. If `start` is nil, notify once with `Logger.notify` (WARN) that the replay could not be matched to the session file, and add nothing.
     5. Otherwise dispatch the held updates from `start` on through the same handlers, with `_loading` still set.
   - `session/load` callback, success: delete `chat_history.dirty = false` and the `drop_deciders` call. After the config options and `set_pending_initial_model` are applied, call `_history_changed` only when `chat_history.dirty`. A load without a tail writes nothing. Run `_restore_transcripts` only on the no-file path.
   - `session/load` callback, error: clear `_replay_hold` and delete the `drop_deciders` call.
   - `_refresh` and `_cancel_session`: clear `_replay_hold` where they clear `_loading`.
   - The `_loading` gates for subagent content (`agent_message_chunk`, `agent_thought_chunk`, `_on_tool_call`, `_on_tool_call_update`) assume that the file holds the subagent's output. With the hold, covered updates never reach them. Change them to record the update in `subagent_messages` and skip only the write to the transcript buffer, which `_open_agent` unloads while `_loading`. Opening the transcript renders it from the history (`_replay_transcript`). `_on_tool_call` also runs `_note_agent_task` while loading.
4. `session-lifecycle` skill: in the `session/load` section, the file renders the chat, and the replay adds only the tail after alignment.
5. Delete `notes/bug-load-save-drops-file-only-content.md`.
6. Tests
   - `session_replay_align.test.lua`, `tail_start`:
     - no tail when the replay holds the same turns;
     - a new turn after the file's end is the tail;
     - prompts and text-only turns after the file's last tool call are not a tail;
     - file rows the replay never sends (SubAgent ids, `Agent` launch calls, synthetic ids, hidden commands) do not break the match;
     - replay-only rows after the last match do not start a tail;
     - a prompt that the replay moves after agent text still matches;
     - a file cut off mid-turn: the rest of that turn is not a tail, and the next prompt is;
     - repeated prompt texts match by order;
     - nil when both sides have keys and none match.
   - `session_manager.test.lua`:
     - replace "keeps the saved deciders for the replayed tool calls" with "the rendered tool calls carry `decided_by` from the file";
     - delete "drops held deciders once the load has …";
     - while loading with a file, a conversation update is held and an `available_commands_update` is applied;
     - `/new` and `_refresh` during a load clear the hold, and a later live turn renders;
     - the no-`loadSession` path renders once and sets no hold;
     - a tail subagent's output is recorded in `subagent_messages`.
   - `tests/integration/test_session_load.lua`. Set `Config.session_restore.storage_path = vim.fn.tempname()`, write a session file there, and use the real `ChatHistory.read`. Then replay the same turns plus one new turn:
     - the chat shows the file's rows once, followed by the new turn;
     - `chat_history.timestamp` is the file's;
     - a hidden-command row and a `cancelled` tool call survive the load and one save;
     - a second load of the saved file adds nothing;
     - a load without a tail does not write the file;
     - an error after the render shows the chat once.
   - `acp_client.test.lua` and the adapter test: `is_replay_only_prompt`.

## Expected outcome
- A loaded session shows what the plugin rendered live: hidden commands, cancelled calls, subagent blocks with their transcripts, and prompts in the order they were sent.
- The session file keeps its timestamps and everything else it held. A load without new turns does not write it.
- Turns added outside the plugin, for example with `claude --resume`, show after the file's content and are saved, subagent output included.
- If the replay cannot be matched to the file, the file wins and a warning says so.

## Non-goals
- Opening a session that has no plugin file (started in `claude`). That needs a session list from the transcripts or from ACP `session/list`.
- Replay quirks inside the tail: replay subagent ids, changed bodies, load-time timestamps.
- The rest of a turn that was cut off in the file. Its agent text has no key, so it cannot be told from text the file already holds.

## Open questions
None.
