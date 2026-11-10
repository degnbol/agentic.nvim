# Plan: one field write to a tool call's block and history record
Status: reviewed spec

## Relevant files
- `lua/agentic/ui/agent_view.lua` — `show_causes`
- `lua/agentic/session_manager.lua` — `_apply_tool_call_fields`, its two
  calls in `_sync_job_stop`, `_apply_side_tool_call`
- `lua/agentic/subagents.lua` — `_set_agent_info`, `record_writer`
- Tests: `lua/agentic/ui/agent_view.test.lua`, `lua/agentic/session_manager.test.lua`
- Skills: `implement`, `lua-class`, `provider-system`

## Background
Four sites merge fields into a tool call's history record, and into its block
when a writer tracks it, without normalising:
- `AgentView:show_causes`
- `SessionManager:_apply_tool_call_fields(writer|nil, fields)` — used twice by
  `_sync_job_stop`
- `SessionManager:_apply_side_tool_call` — after its hold check
- `Subagents:_set_agent_info` — through `record_writer`, nil for a transcript
  that is not loaded

Each copy writes `update_tool_call_block` and
`history:update_tool_call(id, ChatHistory.tool_call_record(update))` by hand.
A rule added to one (a record field, a block refresh) misses the others.
`_apply_tool_call_fields` is already the general form. Two callers have only a
writer that can be nil, not a view, so the shared function takes a writer.

`show_causes` and `_set_agent_info` also copy the current `status` into their
update. Both merges (`MessageWriter:update_tool_call_block`,
`ChatHistory:update_tool_call`) keep a field the update leaves out, so the copy
only satisfies `ToolCallBase`, whose `status` is required.

## Changes
`agent_view.lua` gets the module function that `_apply_tool_call_fields`
holds today, with the history as a parameter:
```lua
--- Merge `fields` into a tool call's history record, and into its block when
--- `writer` tracks it. Does not persist the history.
--- @param writer agentic.ui.MessageWriter|nil
--- @param history agentic.ui.ChatHistory
--- @param fields { tool_call_id: string } `ToolCallBase` fields; those left out stay as they are
function AgentView.merge_tool_call_fields(writer, history, fields)
```
- `AgentView:show_causes` keeps its guard, then calls
  `AgentView.merge_tool_call_fields(self.writer, history, { tool_call_id = …, causes = causes })`.
  The `status` copy goes.
- `SessionManager:_apply_tool_call_fields` is deleted; the two
  `_sync_job_stop` sites call
  `AgentView.merge_tool_call_fields(…, self.chat_history, …)`.
- `SessionManager:_apply_side_tool_call` calls it after the hold check, then
  `_history_changed`.
- `Subagents:_set_agent_info` calls it with `record_writer(block, false)`,
  `self._host.history()` and `{ tool_call_id = child_id, subagent = subagent }`,
  then `history_changed`. The `status` copy goes.

Tests:
- `agent_view.test.lua`: `merge_tool_call_fields` merges into block and
  record for a tracked call; into the record only for a nil writer and for a
  writer that does not track the call; keeps fields the update leaves out
  (`status`). The `show_causes` cases stay.
- `session_manager.test.lua`: the session table of the "tool call handlers"
  cases drops `_apply_tool_call_fields`.

## Expected outcome
One function writes non-normalised tool call fields to block and history.
One behaviour change: `_set_agent_info` with a loaded writer that does not
track the block (after a collapse drops its tracker) today calls
`update_tool_call_block`, which warns "Tool call update for unknown block".
With the tracked check it updates the history only, as `_sync_job_stop` does.
No field is lost: the history keeps it, and a transcript renders from the
history when it loads.

## Non-goals
- `AgentView:update_tool_call`: it normalises, and warns on an untracked
  block.
- `_end_open_tool_calls`, `Subagents:end_agent` and `_mark_stopped`,
  `stop_generation` (`stamp_open_calls` + `update_tool_calls`): they write
  many calls at once, from the writer's own result.
- Changing `record_writer` to return a view: its `_tagfunc` caller uses the
  writer only.

## Open questions
None.
