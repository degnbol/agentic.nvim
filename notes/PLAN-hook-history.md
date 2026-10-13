# Plan: keep hook rows in the chat history
Status: spec

Requires:
- `notes/PLAN-hooks_in_chat.md`, which adds `agentic.ui.MessageWriter.HookBlock` and `write_hook_block(block)`.
- `notes/PLAN-load-file-first.md`. Today a `session/load` rebuilds `messages` from the provider's replay, which has no hook rows, and the first save after it deletes them from the file. With that plan, a load renders and keeps the file's messages, hook messages included.

## Relevant files
- `lua/agentic/ui/chat_history.lua` and `.test.lua` — `agentic.ui.ChatHistory.Message` alias, `add_message`, `prepend_restored_messages`
- `lua/agentic/session_restore.lua` and `.test.lua` — `replay_messages`, `format_preview`
- `lua/agentic/session_manager.lua` and `.test.lua` — `_drain_hook_records`, `_reload_chat`, the `session/load` callback in `_do_load_acp_session`, `_fallback_restore_from_local`, `restore_from_history`
- `lua/agentic/ui/message_writer.lua` — `write_hook_block` docstring ("Not persisted")
- `notes/PLAN-load-file-first.md`
- Skills: `session-lifecycle`

## Background
Hook rows go only to the chat buffer. Every path that rebuilds the chat from `ChatHistory` loses them: `_reload_chat`, `restore_from_history` and the local fallback after a failed `session/load`.

The history keeps messages in the order they were written, and a hook row is written when its drain runs. On replay, the tool call a record names comes earlier in the list, so `write_hook_block` puts the row under the replayed block. A record from a turn-boundary event names no call, so it is appended at the same point where it was appended live.

The transcript cannot be the store. A local fallback restore starts a new session with a different transcript. Also, turn-boundary records have no anchor in the replayed chat.

Hook rows are not sent to a new session (`prepend_restored_messages`). That session's own hooks inject fresh context, and the old injections would read as stale conversation. The `if` chain there and in `format_preview` already ignores unknown types.

## Changes
1. `chat_history.lua`: add the variant and include it in the `Message` alias.
   ```lua
   --- @class agentic.ui.ChatHistory.HookMessage : agentic.ui.MessageWriter.HookBlock
   --- @field type "hook"
   ```
2. `session_manager.lua`, `_drain_hook_records`: build one `HookMessage` per record. Pass it to `write_hook_block` and to `chat_history:add_message`. When it added at least one, call `self:_history_changed(self.chat_history)` once. A drain also runs outside a turn (local commands reach `_finalize_turn`, and a late tool call update can arrive), and nothing else saves after it.
3. `session_restore.lua`, `replay_messages`: `elseif msg.type == "hook" then writer:write_hook_block(msg)`.
4. `message_writer.lua`: delete the "Not persisted" paragraph from the `write_hook_block` docstring.
5. Tests
   - `session_manager.test.lua`: a drain adds one `hook` message per record.
   - `session_restore.test.lua`: `replay_messages` puts a hook message under its replayed tool call, and appends one that names no call.
   - `chat_history.test.lua`: `prepend_restored_messages` sends nothing for a hook message.

## Expected outcome
- `:e` on the chat buffer, `restore_from_history` and the local fallback show the hook rows again, in their original places.

## Non-goals
- Showing hook rows in the picker preview.
- Hook messages of subagents. The reader does not follow subagent transcripts.
- The `session/load` path. `PLAN-load-file-first.md` covers it.

## Open questions
None.
