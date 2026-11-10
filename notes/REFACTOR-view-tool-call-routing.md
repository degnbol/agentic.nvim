# Plan: one tool-call write path for every agent view
Status: reviewed spec

## Relevant files
- `lua/agentic/ui/agent_view.lua` — `AgentView`
- `lua/agentic/session_manager.lua` — `_on_tool_call`, `_on_tool_call_update`,
  `_on_permission_decided`
- `lua/agentic/background_session.lua` — `_on_tool_call`,
  `_on_tool_call_update`, `_show_causes`
- `lua/agentic/ui/chat_history.lua` — `tool_call_record`, `add_message`,
  `update_tool_call`
- `lua/agentic/acp/canonical_tool_call.lua` — `normalise`
- Tests: `lua/agentic/ui/agent_view.test.lua`,
  `lua/agentic/session_manager.test.lua`, `lua/agentic/background_session.test.lua`
- Skills: `implement`, `lua-class`, `provider-system`, `rendering`

## Background
`BackgroundSession` writes tool calls to its transcript with a reduced copy of
`SessionManager`'s routing: default the status, normalise, attach held causes,
write the block, record it in the history; on an update, normalise with the
known kind, keep the first rejection line, update block and history; on
decided causes, skip unchanged ones and update block and history. A copy
drifts: a rule added to one path misses the other. The view-plus-history step
is the same for every agent view;
what differs per caller (subagent claims, held side-record updates, edit
ranges, file ops, job tails, checktime, history-changed hooks) stays with the
caller.

## Changes
`agent_view.lua`, three methods. Each writes to `self.writer` and `history`
only; the class docstring gains that a view records its writes in a given
history. `write_tool_call` sets the default status on `call` in place, as
today:
```lua
--- @param history agentic.ui.ChatHistory
--- @param call agentic.ui.MessageWriter.ToolCallBlock Status defaults to pending
--- @param causes agentic.PermissionCause[]|nil
--- @param agent_key string|nil History key of the agent that sent it; nil for a main agent
--- @return agentic.ui.MessageWriter.ToolCallBlock written The normalised block
function AgentView:write_tool_call(history, call, causes, agent_key)

--- Normalise with the block's known kind, keep the block's first rejection
--- line, update block and history.
--- @param history agentic.ui.ChatHistory
--- @param update agentic.ui.MessageWriter.ToolCallBase
--- @return agentic.ui.MessageWriter.ToolCallBase applied The normalised update
function AgentView:update_tool_call(history, update)

--- @param history agentic.ui.ChatHistory
--- @param tool_call_id string
--- @param causes agentic.PermissionCause[]
--- @return boolean changed False when the call has no block or already shows `causes`
function AgentView:show_causes(history, tool_call_id, causes)
```
- `SessionManager:_on_tool_call` calls
  `view:write_tool_call(self.chat_history, tool_call, self.permission_manager:take_causes(id), agent_key)`
  after merging held updates, and continues with the returned block.
- `SessionManager:_on_tool_call_update` calls `view:update_tool_call` and
  continues with the returned update: the status checks after it read the
  normalised status.
- `write_tool_call` and `update_tool_call` end with
  `self.status_indicator:reposition()`; the callers drop theirs. The
  `Subagents` synthetic SubAgent block write (`subagents.lua`) becomes
  `write_tool_call` with `causes = nil`. The history write now comes before `_try_record_edit_range` and
  `_record_file_op` in `_on_tool_call_update`; neither reads the history.
- `SessionManager:_on_permission_decided` keeps its `destroyed` guard, calls
  `view:show_causes`, and takes the causes and marks the history changed only
  when it returns true. Taking the causes moves after the block update; the
  writer does not read the permission manager.
- `BackgroundSession`'s three methods become calls to the same, plus its
  tripwire check, its `_destroyed` guard in `_show_causes`, and
  `_mark_unmodified`.

## Expected outcome
No behaviour change. A rule added to a view's tool-call write reaches the main
chat, subagent transcripts and background transcripts at once.

## Non-goals
- Agent message and thought chunks: `SessionManager` drains side records
  between filtering a chunk and writing it, so that path stays per caller.
- Permission request handling.

## Open questions
None.
