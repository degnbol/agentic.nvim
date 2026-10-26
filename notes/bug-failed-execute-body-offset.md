# Bug: failed execute block may highlight the wrong rows

Found by a read-only audit (2026-10-26); not reproduced, and not checked whether a failed execute update carries a `body`.

## Observed in code
`lua/agentic/ui/tool_call_renderer.lua:1433-1458`: when a failed execute call has both a failure reason and a `body`, the failure-reason branch draws the reason in place of the body. `body_start_offset` is still computed from `#tool_call_block.body`. The ANSI rewrite (:1450-1452) and the grep term highlighting then address rows by that offset, so they can colour or rewrite the reason lines or the header.

## To establish
- Whether claude-agent-acp (installed bridge 0.95.0) sends `status = "failed"` with output content for a Bash call, e.g. a non-zero exit.
- What the block should show then: reason, output, or both (a display decision for the user).

## Related
`rendering` skill; `MessageWriter:update_tool_call_block`.
