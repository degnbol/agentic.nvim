# Plan: prose cursor and step line in place of the status word
Status: spec

## Relevant files
- `lua/agentic/ui/status_indicator.lua` (+ test), `lua/agentic/ui/agent_view.lua`
- `lua/agentic/ui/message_writer.lua` (`write_message_chunk`,
  `_end_prose_run`, `_abandon_prose_run`, `reset`, `finalize_turn`,
  `flush_thought_run` docstring)
- `lua/agentic/session_manager.lua`: `_on_message_chunk`'s indicator block,
  `_on_request_permission`'s answer callback, `_on_tool_call_update`'s status
  block, `_dispatch_turn`, `new_session`'s `create_session`,
  `load_acp_session`, `_start_fork`'s `fork_session`, and the stops in
  `_refresh`, `stop_generation`, the prompt callback, the create/load/fork
  callbacks and `_reset_conversation`
- `lua/agentic/subagents.lua` (`_start_agent`, `transcript`, `end_agent`,
  `forget`, `reposition` calls), `lua/agentic/ui/subagent_transcript.lua`,
  `lua/agentic/background_session.lua` (start and end)
- `lua/agentic/config_default.lua` (`bottom_padding` docstring),
  `lua/agentic/theme.lua`, `lua/agentic/glyphs.lua`
- Tests: `session_manager.test.lua`, `subagents.test.lua`,
  `agent_view.test.lua`, `subagent_transcript.test.lua`,
  `tests/integration/test_native_subagents.lua` (`_G.indicator_at_end`),
  `test_session_load.lua`, `test_fork.lua`
- `.claude/skills/issues/references/chunk-flush.md`
- Skills: `rendering`, `follow`, `neovim` → `references/rendering.md`

## Background
`generating`, `thinking` and `busy` are the plugin's own words; no provider
sends them. Each is set by the kind of the last event, so they say what came
last, not what the agent does: `generating` stays during subagent waits and
long tool calls, `thinking` after submit only says "no reply yet" (the
header's `running` says that), `busy` hides which step runs, `searching` is
never set.

Whether an agent works or waits for the user is in the header (`permission` /
`running` / `idle`) and in each tool call block's status icon. What is left:
where prose is being written, and which of the plugin's own steps runs.

## Changes
- Prose cursor, owned by `MessageWriter`: an inline extmark
  (`virt_text_pos = "inline"`, glyph `▎` in `glyphs.lua`, group
  `AgenticProseCursor` linked to `NonText`) at the end of the last line.
  - Placed at the end of `write_message_chunk`, only while the view's agent
    runs: the chat while the turn is open and not replaying, a transcript
    while its subagent is open (a `MessageWriter` flag set by the owner).
  - Re-placed on each chunk (wrap and reflow use `set_lines`).
  - Deleted in `_end_prose_run`, `_abandon_prose_run`, `reset`,
    `finalize_turn`, and at `end_agent`.
  - The hard wrap counts the cursor's column: wrap at `#tail >= wrap_width`
    while the cursor shows.
- `StatusIndicator` becomes `StepLine` (`show(text)`, `clear()`): the bottom
  `virt_lines` mark, for the plugin's own steps: `starting session`,
  `loading session`, `forking`. Replaces `start("busy")`.
- Remove the `generating`/`thinking` starts and switches and the `State`
  alias; remove transcript `reposition` calls.
- Thought runs show nothing while held: a thought arrives whole, so it has
  ended when it arrives. Fix the `flush_thought_run` docstring, which says
  the indicator shows "thinking" meanwhile.
- `bottom_padding` docstring: for the step line.
- Update the tests above (`indicator_at_end` reads the cursor mark) and
  `chunk-flush.md`.

## Expected outcome
- While prose streams, a bar shows at its end. It goes when anything else
  follows the prose, or the turn or subagent ends.
- Between prose (tool calls, subagent waits) no word shows at the bottom.
- New session, load and fork show which step runs until it ends.

## Non-goals
- Which subagents run (agents panel plan).
- Animation.

## Open questions
None.
