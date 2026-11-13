# Bug: a family kind's head drops its detail on a later update

Affects the `Cron` family (`CronCreate`, `CronDelete`, `CronList`): the head
`CronCreate: <cron>` likely becomes `CronCreate` once the call completes.

Likely cause (not yet proven with a test):
`ClaudeAgentACPAdapter:__apply_tool_identity` runs on every update and writes
`ClaudeUtils.tool_head(kind, {}, tool_name)`. For a family kind that head is
the bare tool name, never `""`, so `set_head` writes it. An update without
`rawInput` (the completed status update) then carries
`argument = "<ToolName>"`, and the "force" merge in `update_tool_call_block`
replaces the refined `<ToolName>: <detail>` head.

Evidence: session 09ea7913 (merops) saved `argument = "TaskStop"` for a call
whose input was `{"task_id":"bdod3zl0w"}`. TaskStop was in the same family
then; it now has a kind of its own.

Reproduce: adapter test with a `CronCreate` refinement carrying `cron`, then a
completed update without `rawInput`; check the merged `argument`.
