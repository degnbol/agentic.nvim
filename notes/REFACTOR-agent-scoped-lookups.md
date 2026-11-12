# Plan: one side-record drain and one transcript lookup per agent
Status: reviewed spec

## Relevant files
- `lua/agentic/session_manager.lua` — `_drain_side_records`,
  `_drain_subagent_side_records`, `_drain_side_records_of`,
  `_apply_side_tool_call`, the `end_side_records` host closure in
  `_subagents_host`; callers in `_on_agent_chunk`, `_on_tool_call`,
  `_on_tool_call_update`, `_finalize_turn`, the prompt callback in
  `_dispatch_turn`; `_writers_of_message`, which calls `transcript_of_key`.
  The `record_writer` callers (`_tagfunc`, `_sync_job_stop`,
  `Subagents:_set_agent_info`) keep their signature.
- `lua/agentic/subagents.lua` — `_child_of_key`, `transcript`,
  `transcript_of_key`, `loaded_transcript_of_key`, `record_writer`,
  `_set_agent_info`
- `lua/agentic/acp/acp_client.lua` — `ACPClient:drain_side_records(session_id, child_id)`
  (contract, unchanged)
- Tests: `lua/agentic/session_manager.test.lua` (`_drain_side_records`,
  `_drain_subagent_side_records`, stubs of all three drains),
  `lua/agentic/subagents.test.lua` (`record_writer`),
  `tests/integration/test_native_subagents.lua`
- Skills: `subagents`, `implement`

## Background
### Drains
`_drain_side_records()` drains the main agent's records. It reads every
subagent's record, applies `tool_call` fields, writes received messages, and
writes and stores the rest. `_drain_subagent_side_records(child_id)` repeats
the guard and the loop for one subagent and applies only `tool_call`
fields. A subagent's hook activity and loaded files are not shown.
`_drain_side_records_of(child_id)` exists only to pick between the two.
Each record kind already says how to handle it. Which agent drained it
decides only whether `read_records` runs and whether the non-`tool_call`
kinds are shown. So one drain
over `child_id` is the function one would write with both needs known.

### Transcript lookup
`transcript_of_key(key)` makes, loads and renders a subagent's transcript.
`loaded_transcript_of_key(key)` returns it only when it exists and is
loaded. Both start with `_child_of_key`. `record_writer(record, make)`
exists to pick between them, and it already carries the `make` flag that
belongs on the lookup.

## Changes
### `session_manager.lua`
- `_drain_side_records(child_id)`: `child_id` is the subagent, nil for the
  main agent. It replaces all three functions. Body:
  - The guard (`destroyed`, `session_id`) as today.
  - `self._subagents:read_records()` only when `child_id` is nil, as today:
    it links main-agent calls to subagents, and today's subagent drain does
    not call it.
  - The loop over `self.agent:drain_side_records(self.session_id, child_id)`.
    `tool_call` → `_apply_side_tool_call(side.tool_call, child_id)`.
    The next branch is `elseif child_id`, before `received_message`: records
    of other kinds from a subagent are skipped, with the current
    docstring sentence "Its hook activity and loaded files are not shown"
    moved onto that branch. Main-agent `received_message` and placed
    records behave as today.
  - `store_placed` and the `_history_changed` call as today. They run only
    when something was placed, which only the main agent does.
- Delete `_drain_subagent_side_records` and `_drain_side_records_of`.
- Callers: `_drain_side_records_of(child_id)` (in `_on_tool_call` and
  `_on_tool_call_update`) → `_drain_side_records(child_id)`. The `end_side_records` host closure →
  `self:_drain_side_records(child_id)`. The four argument-less callers stay
  as they are.
- Docstring: lead with "Handle the side records an agent recorded since its
  last drain". `@param child_id`: "The subagent, nil for the main agent".
  The rest says what the main agent's records do.

### `subagents.lua`
- `transcript_of_key(agent_key, make)`: `make` true behaves as today's
  `transcript_of_key`, and false as `loaded_transcript_of_key`. The docstring
  says that `make` is a required boolean. Delete `loaded_transcript_of_key`.
- `record_writer(record, make)`: `local transcript = self:transcript_of_key(agent_key, make)`.
- `session_manager.lua` call `transcript_of_key(msg.agent_key)` →
  `transcript_of_key(msg.agent_key, true)`.

### Tests
- `session_manager.test.lua`: move the `_drain_subagent_side_records` cases
  under `_drain_side_records` and call it with `"a1"`. Add assertions to
  them that a subagent's `hook` record is not written or stored, its
  `tool_call` is applied with `child_id`, and `_subagents.read_records` is
  not called. Replace the stubs of the
  three names with one `_drain_side_records` stub that records its argument
  (the `make_session` stub of the `_on_tool_call_update` cases, and the
  noop stubs of the "tool call handlers" cases). A nil argument must be
  recorded as an entry, e.g. `table.insert(drains, { child_id })`.
  "keeps a subagent's held updates past the turn's end" calls
  `_drain_side_records("a1")`; `record_tool_call` already installs the real
  drain, so its stub assignment goes.
- `subagents.test.lua`: `transcript_of_key(key, false)` returns nil for an
  unloaded transcript and makes nothing. `true` loads it. The `record_writer`
  case stays.
- `tests/integration/test_native_subagents.lua`: unchanged (argument-less
  calls).

## Expected outcome
No behaviour change. One drain and one lookup, each taking the agent or the
`make` choice as an argument. The choice moves inside them, and the
functions that only picked between twins are gone.

## Non-goals
- Showing a subagent's hook activity or loaded files.
- Merging `Subagents:transcript(child_id)` into `transcript_of_key`. Its
  callers hold a child id and always make the transcript.

## Open questions
None.
