# Plan: Failed execute block body offset
Status: reviewed (open questions)

## Relevant files
- `notes/bug-failed-execute-body-offset.md` (the report)
- `lua/agentic/ui/tool_call_renderer.lua` — `prepare_block_lines`: execute fence unwrap :825-834, failure-reason branch :1003-1033, `body_start_offset` :1433-1441, ANSI rewrite :1446-1458, grep highlights :1462-1501
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua` — `__build_tool_call_update` :256-272; `__apply_raw_input` returns early on empty `rawInput` :332-334
- `lua/agentic/acp/acp_client.lua` — `extract_content_body` :704-717 (reads `content[1]` only), `extract_failure_reason` :741-765, base `__build_tool_call_update` :833-844, client capabilities `terminal = false`, no `_meta.terminal_output` :123-137
- `lua/agentic/ui/message_writer.lua` — `update_tool_call_block` body merge :2841-2851, `nvim_buf_set_lines` :3005
- Bridge 0.95.0 (`~/.local/share/npm/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist`): `tool-calls/reporters/bash.js:29-31`, `tool-calls/renderer.js:207-215,282-337,436-460`, `tool-calls/content.js:46-76`, `tool-calls/client-capabilities.js:39-42`, `exit-plan.js:111-117`, `acp-agent.js:4426-4475` (`permission_denied`)
- Trace scripts: `/tmp/agentic_review/trace_denial.lua`, `/tmp/agentic_review/trace_ansi.lua`
- Skills: `rendering`, `provider-system`

## Background
Root cause: `prepare_block_lines` derives the drawn body rows from `tool_call_block.body` (`body_start_offset` :1433-1441, ANSI rewrite :1446-1458, grep :1462-1501), whatever list the branch drew. The failure branch (:1003-1033) draws `failure_reason`. When `#body ~= #failure_reason`, the ANSI rewrite and grep highlights address the wrong rows.

What bridge 0.95.0 sends for a failed Bash result to this client:
1. The plugin advertises neither `_meta.terminal_output` nor `_meta.terminal_output_delta` (acp_client.lua:123-137) and speaks protocol v1, so `ClientCapabilities.terminalOutput` is false (client-capabilities.js:39-42).
2. `resultFacts` calls `BashReporter.errorResult` (renderer.js:213-214), which returns `undefined` without `terminalOutput` (bash.js:29-31). The update is `toAcpContentUpdate(content, true)`: for string content, one `content` entry "```\n<content>\n```" (content.js:65-76).
3. `rawOutput` is the same `content` (renderer.js:308-311, exit-plan.js:111-114).

So for a plain failure, body and reason come from the same string. The adapter keeps the body fenced (no `rawInput`, claude_agent_acp_adapter.lua:332-334), the renderer unwraps it (:825-834), and the two lists match. Claude Code sends a failed Bash result as one string.

A mismatch is reachable through a deny-rule denial:
1. `permission_denied` (acp-agent.js:4426-4475) sends `permissionDenied` (renderer.js:436-460): `status: "failed"`, content "Permission denied: <reason>", no `rawInput`, no `rawOutput`.
2. The error `tool_result` then sends a second failed update with fenced content and `rawOutput`.
3. message_writer.lua:2841-2851 merges the two bodies with a divider (7 lines), while `failure_reason` is 1 line. The unwrap (:825-834) does not fire, because the merged body does not start with a fence.

Without ANSI, the wrong offset is harmless in practice. With ANSI in the merged body, the rewrite writes `lines[0]`, `nvim_buf_set_lines` fails with "Expected Array-like Lua table" (message_writer.lua:3005), and the block stays stale (`trace_ansi.lua`). `trace_denial.lua` shows the merged case without ANSI.

## Changes
Depends on open question 1. If fixed: the drawing branch records which list it drew, and the offset, ANSI and grep passes read that list instead of `tool_call_block.body`.

## Expected outcome
With the fix, ANSI and grep highlights land on the drawn rows for every branch, and a denied execute block with ANSI output updates instead of staying stale.

## Non-goals
- A client terminal capability (`_meta.terminal_output`), which would change the update shape.

Other providers: base `ACPClient:__build_tool_call_update` (acp_client.lua:833-844) pairs `body` and `failure_reason` the same way. A root fix in `prepare_block_lines` covers all providers.

## Open questions
1. Fix the offset, or not?
2. What does a denied execute block show: the SDK message only, also the rule line, or the rule line only? And, with that, the reason, the output, or both?
