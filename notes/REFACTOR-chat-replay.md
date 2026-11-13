# Plan: one replay of the history into the main chat
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/session_manager.lua` — `_reload_chat`, `_render_history`
- `lua/agentic/subagents.lua` — `add_history_transcripts` (unchanged)
- Tests: `lua/agentic/session_manager.test.lua` (stubs of `_render_history`
  at the `_do_load_acp_session` and `replace_with_history` cases, unchanged);
  `tests/integration/test_buffer_lifecycle.lua` (`describe(":e!")` and the
  mid-turn `:e!` cases)

## Background
`_reload_chat` and `_render_history` both replay `self.chat_history.messages`
into `self.message_writer` with the subagent buffer-name resolver, then
reposition the status indicator. So "how the main chat is drawn from the
history" has two copies.

`_reload_chat` cannot call `_render_history`: `add_history_transcripts`
replaces the agent record of a subagent whose transcript was wiped, which
drops a live agent's `open` flag. So the shared part becomes its own method.

## Changes
1. Add `SessionManager:_replay_chat` (Additions) with the
   `SessionResume.replay_messages` call and `status_indicator:reposition()`.
2. `_render_history`: `add_history_transcripts()`, then `_replay_chat()`.
   Its comment about the history's own messages stays above the two calls:
   its reason is the `add_history_transcripts` call, which `_replay_chat`
   does not make.
3. `_reload_chat`: `main_view:restart()`, `_replay_chat()`,
   `_sync_modified(self.chat_history)`.

## Additions
### `session_manager.lua`, above `_render_history`
```lua
--- Write `self.chat_history`'s messages into the chat, which must be empty.
function SessionManager:_replay_chat()
```

## Tests
No new test: the change moves two statements. Existing cases that must pass:
the `_render_history` stub cases in `session_manager.test.lua`, and the
chat `:e!` reload cases in `tests/integration/test_buffer_lifecycle.lua`.

## Expected outcome
No behaviour change.

## Non-goals
- Calling `add_history_transcripts` on reload.
- `SessionResume.replay_messages` (see `notes/REFACTOR-read-range-on-load.md`
  for its `tool_call` branch).

## Open questions
None.
