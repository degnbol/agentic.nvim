# Plan: `ResponseBoundary:filter_chunk` takes any agent chunk
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/acp/response_boundary.lua` — `filter_chunk`
- `lua/agentic/session_manager.lua` — `_on_agent_chunk`
- `lua/agentic/background_session.lua` — `_on_session_update`
- Tests: `lua/agentic/acp/response_boundary.test.lua`
  (`describe("filter_chunk")`); `session_manager.test.lua` and
  `background_session.test.lua` (existing chunk cases, unchanged)

## Background
`SessionManager:_on_agent_chunk` and `BackgroundSession:_on_session_update`
hold the same `if is_message then … end` block: a message chunk goes through `response_boundary:filter_chunk`
and is dropped when no text is left; a thought chunk is written as sent.
Which chunks the boundary sees is the boundary's rule, so it goes in
`filter_chunk`.

## Changes
1. `response_boundary.lua`, `filter_chunk(update)`: `update` is
   `agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk`. A chunk
   whose `sessionUpdate` is not `"agent_message_chunk"` returns
   `update, false` and does not change the boundary's state. The docstring
   lead becomes "Run an agent chunk through the boundary. A thought chunk
   passes through and is not part of the stream; a message chunk's text is
   filtered. `update` is not modified." The `chunk` return type is the same
   union, `|nil`.
2. `session_manager.lua`, `_on_agent_chunk`: the block becomes
   ```lua
   local chunk, starts_response = view.response_boundary:filter_chunk(update)
   if not chunk then
       return
   end
   ```
   `is_message` stays: later lines use it.
3. `background_session.lua`, `_on_session_update`: the same two statements.
   Remove the `--[[@as agentic.acp.AgentMessageChunk]]` cast.

## Tests (`response_boundary.test.lua`, `describe("filter_chunk")`)
Write first. Add "passes a thought chunk through": after a message chunk
`("X", "a")`, a thought chunk (`sessionUpdate = "agent_thought_chunk"`,
built by a `kind` argument on the local `chunk` helper) with
`messageId = "Y"` and text `"\nb"` returns the same table and false. A
message chunk `("X", "c")` after it returns text `"c"` and false, so the
thought did not record its id. Existing cases pass unchanged.

## Expected outcome
No behaviour change. The main and background sessions call the boundary the
same way, with no kind test of their own. A thought chunk's
`starts_response` is `false` where it was `nil`; every reader
(`write_message_chunk`, `ChatHistory:append_agent_text`, the drain
condition in `_on_agent_chunk`) tests it for truth only.

## Non-goals
- The drain of side records in `_on_agent_chunk`.
- Subagent text written per chunk.

## Open questions
None.
