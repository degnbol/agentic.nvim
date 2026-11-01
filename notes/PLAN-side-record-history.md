# Plan: keep side-record rows in the chat history
Status: spec

A `session/load` renders and keeps the file's messages (`b909dda`), so side-record rows saved in the file survive a load. Passed hooks are rows (`MessageWriter:write_hook_row`), and the drain maps Agent-call ids to their SubAgent block in place (`SessionManager:_block_id`).

## Relevant files
- `lua/agentic/ui/chat_history.lua` and `.test.lua` — `agentic.ui.ChatHistory.Message` alias, `TOOL_CALL_FIELDS`, `add_message`, `prepend_restored_messages`
- `lua/agentic/session_restore.lua` and `.test.lua` — `replay_messages`, `format_preview`
- `lua/agentic/session_manager.lua` and `.test.lua` — `_drain_side_records`, `format_duration`, `hook_title`, `_block_id`, `_history_changed`, `_persist_history`, `_reload_chat`, `restore_from_history`, `_fallback_restore_from_local`, the prompt callback's turn-end save
- `lua/agentic/acp/acp_client.lua` — `agentic.acp.SideRecord`
- `lua/agentic/ui/message_writer.lua` — `write_hook_block` docstring ("Not persisted"), `_resolve_anchor`, `is_compaction` / `_last_compaction_id`
- Skills: `session-lifecycle`

## Background
Side records (hooks, loaded files and discovered skills) go only to the chat buffer. Every path that rebuilds the chat from `ChatHistory` loses them: `_reload_chat`, `restore_from_history`, and the local fallback after a failed `session/load`.

One history message per drain, holding the drained `SideRecord[]` as they are, so that replay runs the same code as the live drain:
- A per-kind message would need a new variant, a new replay branch and a new test for each kind.
- Storing records rather than rendered blocks makes `agentic.acp.SideRecord` an on-disk schema: renaming one of its fields needs a migration in `ChatHistory.from_data`. Its docstring says so. The Claude-only fields the adapter leaves on a record (`timestamp`, `hook_event`) are stored too; they are harmless and not read back.

The history keeps messages in write order, and a drain's message is added when the drain runs. On replay, the anchor a record names was written earlier, so the writer finds it:
- A tool call anchor: the replayed block.
- A prompt anchor: the last prompt replayed, which holds because the message was added in its prompt's turn.
- A compaction anchor: `_resolve_anchor` reads `_last_compaction_id`, which `write_tool_call_block` sets from `is_compaction`. The history drops `is_compaction` today (it is not in `TOOL_CALL_FIELDS`), so it must be stored.
- No anchor: appended at the same point where it was appended live.

Replay reads kinds from a file, which a newer build may have written. A kind the dispatch does not know is skipped with a notification, never an error, so one unknown record cannot break a replay.

The drain saves through `_history_changed`, because a drain also runs outside a turn (local commands reach `_finalize_turn`, and a late tool call update can arrive) and nothing else saves after it. At a turn end the prompt callback has already decremented `_prompt_pending` when `_finalize_turn` drains, so a drain with records saves once and the callback saves again; during a retry the drain saves although the callback skips its save. Accepted: one extra synchronous write on a turn end that had side records. Avoiding it would mean moving the save to every out-of-turn drain site.

The transcript cannot be the store. The load fallback starts a new session with a different transcript, and turn-boundary records have no anchor in the replayed chat.

The messages are not sent to a new session (`prepend_restored_messages`). That session's CLI runs its own hooks, loads its own rules and `@` files, and discovers its own skills, so the old ones would read as stale conversation. The `if` chain there and in `format_preview` already ignores unknown types.

## Changes
1. New `lua/agentic/ui/side_records.lua`: `SideRecords.write(writer, records)` writes `records` (an `agentic.acp.SideRecord[]`) to `writer`, each at the anchor it names, with `passed` hooks written as rows after the rest. It dispatches on each `kind` explicitly; an unknown kind is skipped with one `Logger.notify` per call. The writing part of today's `_drain_side_records` loop moves here, together with `format_duration` and `hook_title`. Nothing else in `session_manager.lua` uses them. The id mapping (`_block_id`) and the agent-record reads stay in the drain, which runs them before `SideRecords.write` and before storing, so stored records already name their block and replay takes no map.
2. `chat_history.lua`:
   - Add the variant and include it in the `Message` alias.
     ```lua
     --- @class agentic.ui.ChatHistory.SideRecordsMessage
     --- @field type "side_records"
     --- @field records agentic.acp.SideRecord[]
     ```
   - Add `is_compaction` to `TOOL_CALL_FIELDS`. It is a `ToolCallBlock` field today; move it to `ToolCallBase`, which the field-sync test compares against.
3. `acp_client.lua`: add to the `SideRecord` docstring that the type is stored in the chat history, so a field rename needs a migration.
4. `session_manager.lua`, `_drain_side_records`: when the drain returns at least one record, call `SideRecords.write(self.message_writer, records)`, add one `side_records` message, and call `self:_history_changed(self.chat_history)`.
5. `session_restore.lua`, `replay_messages`: `elseif msg.type == "side_records" then SideRecords.write(writer, msg.records)`.
6. `message_writer.lua`: delete the "Not persisted" paragraph from the `write_hook_block` docstring.
7. Tests:
   - `side_records.test.lua`: move the drain-dispatch cases from `session_manager.test.lua`, including passes written as rows after the rest. The id-mapping cases stay in `session_manager.test.lua`. An unknown kind is skipped with a notification and the other records are written.
   - `session_manager.test.lua`: a drain adds one `side_records` message holding its records; an empty drain adds none and does not save.
   - `session_restore.test.lua`: `replay_messages` puts a hook and a loaded file under their replayed tool call, puts a prompt-anchored one after its prompt, puts a compaction-anchored one under the replayed compaction block, and appends one with no anchor.
   - `chat_history.test.lua`:
     - `prepend_restored_messages` sends nothing for a `side_records` message.
     - A JSON round trip (`save`, `from_data`) keeps a `side_records` message, including a `passed` hook with an empty body, and keeps `is_compaction` on a tool call.

## Expected outcome
- `:e` on the chat buffer, `restore_from_history` and the local fallback show hook, loaded-file and discovered-skill rows again, in their original places.

## Non-goals
- Showing side records in the picker preview.
- Side records of subagents. The reader does not follow subagent transcripts.
- The `session/load` path, which keeps the file's rows already.

## Open questions
None.
