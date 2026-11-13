# Plan: one binding of a subagent's keys on its transcript and its input
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/subagents.lua` — `_open_input` (the `setup_buf` handler),
  `_new_transcript` (the `setup_buf` handler), `_bind_agent_keymaps`
- Tests: `tests/integration/test_subagent_inputs.lua`;
  `tests/integration/test_buffer_lifecycle.lua` (asserts the transcript's
  "Agentic: Stop subagent" map)
- Notes: `notes/FEAT-per-agent-file-activity.md` binds
  `keymaps.widget.toggle_activity` on both buffers

## Background
The `setup_buf` handler in `_open_input` and `_bind_agent_keymaps` (called
from `_new_transcript`'s `setup_buf`) bind
`keymaps.widget.stop_generation` to `self:stop(child_id)` with the same
`desc`. The key means "stop this subagent" in both buffers, so it is one
binding. `_bind_agent_keymaps` cannot run on the input today: it also binds
`keymaps.agent.to_input`, a map for read-only buffers. That one binding is
the transcript's own, so it moves to the transcript's `setup_buf`, and
`_bind_agent_keymaps` becomes the keys of both buffers.

## Changes
1. `_bind_agent_keymaps(child_id, bufnr)`: only the `stop_generation`
   binding. Docstring: "Bind the keys that act on a subagent, in its
   transcript and its message input: `keymaps.widget.stop_generation`
   cancels the agent's session." `@param bufnr` loses "The transcript".
2. `_new_transcript`, `setup_buf`: `self._host.setup_buf(bufnr, writer)`,
   the `BufHelpers.bind_to_input(Config.keymaps.agent.to_input, …)` call
   moved out of `_bind_agent_keymaps` (with its sentence from the old
   docstring as a comment), then `self:_bind_agent_keymaps(child_id, bufnr)`.
3. `_open_input`, `setup_buf`: `self._host.setup_buf(bufnr, nil)`, then
   `self:_bind_agent_keymaps(child_id, bufnr)`.

No new function. The signature of `_bind_agent_keymaps` is unchanged.

### Tests
Write no new case. Existing cases that must pass: "with no window, output
lands and <C-c> stops that agent" (presses `<C-c>` in the transcript and the
input), "an input reloaded after :bd gets its setup back" (`<C-c>` map on a
reloaded input), the `insert keys` cases (`to_input` from a transcript) in
`test_subagent_inputs.lua`, and the "Agentic: Stop subagent" assertion in
`test_buffer_lifecycle.lua`.

## Expected outcome
No behaviour change. A key that acts on a subagent from both of its
buffers is added in one place.

## Non-goals
- `toggle_activity` (`notes/FEAT-per-agent-file-activity.md`). After this
  plan, that feature adds its binding to `_bind_agent_keymaps`.

## Open questions
None.
