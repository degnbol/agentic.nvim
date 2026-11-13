# Plan: one newest-record search over the history's tool calls
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/ui/chat_history.lua` — `ChatHistory:tool_call`
- `lua/agentic/session_manager.lua` — `_background_job_record`; its callers
  `_tagfunc` and `_sync_job_stop`
- Tests: `lua/agentic/ui/chat_history.test.lua` (`describe("tool_call")`);
  `lua/agentic/session_manager.test.lua` ("falls back to vim.lsp.tagfunc
  when no message or job has the tag" stubs `_background_job_record`; the
  `_sync_job_stop` cases copy it into their session table)
- Notes: `notes/REFACTOR-agent-scoped-lookups.md` changes the body of
  `Subagents:record_writer`, which both callers use on the record found,
  but not the calls; it also edits the drain entries of the `_sync_job_stop`
  cases' session table that this plan edits. Either order works.

## Background
`ChatHistory:tool_call` and `SessionManager:_background_job_record` both
search `messages`, then `subagent_messages`, each from the newest row, for
a `tool_call` record with one field equal to a value: `tool_call_id` in the
first, `background_job_id` in the second. The search order is a fact about
the history, and the second copy lives outside it.

## Changes
1. `chat_history.lua`: add the local `newest_tool_call` (Additions) above
   `ChatHistory:tool_call`. `tool_call(id)` returns
   `newest_tool_call(self, "tool_call_id", id)`.
2. `chat_history.lua`: add `ChatHistory:job_tool_call` (Additions) below
   `tool_call`, returning `newest_tool_call(self, "background_job_id", job_id)`.
3. `session_manager.lua`: delete `_background_job_record`. `_tagfunc` and
   `_sync_job_stop` call `self.chat_history:job_tool_call(...)`.

## Additions
### `chat_history.lua`
```lua
--- The newest tool call record whose `field` is `value`: the main chat's,
--- else the subagents'.
--- @param history agentic.ui.ChatHistory
--- @param field string
--- @param value string
--- @return agentic.ui.ChatHistory.ToolCall|nil
local function newest_tool_call(history, field, value)

--- The record of the tool call that went to the background as `job_id`.
--- @param job_id string
--- @return agentic.ui.ChatHistory.ToolCall|nil
function ChatHistory:job_tool_call(job_id)
```

### Tests
- `chat_history.test.lua`: add `describe("job_tool_call")`: a main and a
  subagent record with the same `background_job_id` returns the main one;
  two main records return the newer; an unknown id returns nil.
- `session_manager.test.lua`: in "falls back to vim.lsp.tagfunc when no
  message or job has the tag", replace the `_background_job_record` stub with
  `chat_history = ChatHistory:new()`. Remove `_background_job_record` from
  the `_sync_job_stop` session table.
- Existing `describe("tool_call")` cases pass unchanged.

## Expected outcome
No behaviour change. The history owns both searches.

## Non-goals
- Indexing records by id.
- `update_tool_call` and the subagent block lookup, which already call
  `tool_call`.

## Open questions
None.
