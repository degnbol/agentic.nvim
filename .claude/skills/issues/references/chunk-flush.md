# The "content appears only on next user submit" symptom

Recurring symptom family. Historically appeared in several contexts, each
with its own root cause. Most contexts are now fixed. The **auto-continue
after usage-limit reset** path is the last known remaining context.

## Symptom pattern (common across all variants)

During the buggy window (while the agent is responding):

**IS written to the chat buffer:**
- User prompt heading (e.g. `## Continue`).
- Status spinner ("thinking", "generating") and transitions between states.
- Permission prompts (numbered accept/reject options) — interactive and
  working.

**IS NOT written:**
- Regular Claude prose text (`agent_message_chunk` stream).
- Entire tool call frames — not just body/content, the whole frame including
  the header line (` ### Read `, ` ### Execute `, etc.).

**Release trigger:**
- The exact moment the user types and submits a new prompt, ALL the missing
  content appears at once in the correct order, above the user's new prompt.

**Not the symptom:**
- `<C-l>` or `:redraw!` revealing content that was already in the buffer —
  that would be a repaint bug, a different class.
- Provider not responding — the provider IS streaming; the bytes reach the
  transport.
- Streaming starting, then stopping mid-response — that's a separate class.

## Historical variants (all fixed)

Search these commits and surrounding history when diagnosing:

- `ddc2b2c Fix parallel tool calls not rendering and add in_progress status`
  — parallel tool calls were invisible because new blocks appended after
  permission buttons (at buffer end), then reanchoring displaced them. Fix
  was to remove permission buttons before appending the next tool call block.
  This was the "parallel tasks" variant the user refers to.
- `e8da343 fix rejection suppression permanently eating message chunks
  across turns` — `_suppressing_rejection` flag not cleared at turn
  boundary; next turn's chunks got swallowed while matching the rejection
  prefix.
- `610472b Reset all per-turn MessageWriter state at turn boundary and on
  refresh` — broader cleanup of per-turn MessageWriter flags so
  `_chunk_start_line`, `_last_wrote_tool_call`, `_last_message_type` can't
  leak either.
- `b053a72 force screen redraw after parallel ACP buffer modifications`
  (reverted in `44445c4 Remove unnecessary vim.cmd.redraw() calls from
  MessageWriter`) — an attempted redraw-based fix that was wrong. Keep this
  in mind — do not re-add redraws for this symptom family.

Pattern: each fix was a distinct root cause (extmark displacement, flag
leak, scheduler-wakeup, etc.), not a single underlying bug. The shared
*symptom* is what recurs; the *cause* varies by context.

## Currently open: auto-continue after usage-limit reset

### Root cause: bridge-level generator stall

**The bug lives in `claude-agent-acp` (the bridge) or its inner
`@anthropic-ai/claude-agent-sdk`, not in the plugin.** Confirmed by
code inspection against `claude-agent-acp` 0.29.0 and
`@anthropic-ai/claude-agent-sdk` 0.2.111. See
`@.claude/skills/acp/references/claude-agent.md` §
"Prompt loop stall — silent notification loss with working
permissions" for the full explanation.

Summary of the asymmetry (this IS real, just at the bridge layer, not
the plugin's dispatch layer as an earlier revision of this file
incorrectly framed it):

- `session/request_permission` is triggered from the SDK's
  `handleControlRequest` side-channel (`acp-agent.js:788, 865` →
  `this.client.requestPermission(...)`), **independent** of whether
  the bridge's prompt loop is making progress.
- `session/update` notifications (`agent_message_chunk`, `tool_call`,
  `tool_call_update`) are emitted *only* after each
  `await session.query.next()` yields inside the bridge's `prompt()`
  loop (`acp-agent.js:313`).

If the inner `claude` CLI subprocess's prompt generator stalls (e.g.
its upstream SSE connection to the Anthropic API has gone half-open
during the multi-hour idle, per
[claude-code#33949](https://github.com/anthropics/claude-code/issues/33949)),
notifications stop arriving while permission requests keep working.
The generator is not closed on `RequestError.internalError`
(`acp-agent.js:449-450, 600-609`), so the bridge reuses the stuck
pipeline for the next prompt.

The "flush on next user submit" shape matches
[claude-agent-acp#551](https://github.com/agentclientprotocol/claude-agent-acp/issues/551)
(after a cancelled turn, next prompt returns end_turn with zeroed
usage and no chunks, prompt after that delivers in full). Related:
[claude-agent-acp#497](https://github.com/agentclientprotocol/claude-agent-acp/issues/497)
(`prompt()` blocks forever on `session.query.next()` when the binary
stops emitting `idle`).

### Ruled out by test

Two plugin layers pass end-to-end integration tests for the
auto-continue sequence:

- **MessageWriter** —
  `tests/integration/auto_continue_chunk_flush.test.lua`. Normal turn
  → usage-limit error → `append_separator` → "## continue" → streamed
  chunks + tool_call + tool_call_update, including the
  rejection-suppression edge case. Per-turn state
  (`_suppressing_rejection`, `_rejection_buffer`,
  `_chunk_start_line`) resets correctly and all content lands in the
  buffer.
- **ACPClient dispatch** —
  `lua/agentic/acp/acp_client.test.lua` → `describe("dispatch after
  error response (auto-continue path)")`. Drives `_handle_message`
  through prompt #1 (usage_limit error response) + prompt #2
  (streamed session/update notifications + end_turn result), plus a
  permission request sandwiched between chunks. All notifications
  reach the subscriber.

These tests cannot reproduce the production bug because the bytes
never leave the bridge — there is nothing for MessageWriter or the
dispatch layer to receive.

### Viable workarounds

Anything at the MessageWriter / dispatch / ACPClient layer is a dead
end. The two approaches that can actually recover:

1. **Respawn before auto-continue.** Before
   `_offer_auto_continue`'s timer callback sends
   `session/prompt("continue")`, tear down the current session via
   `new_session({ on_created = ... })` and resend. This kills the
   stuck claude-agent-acp subprocess, spawns a fresh one, and
   re-establishes the ACP pipeline. Session state is lost unless
   `chat_history` is re-prepended (the plugin already does this for
   session restore). Cost: full subprocess restart per usage-limit
   event, but auto-continue only fires once per reset cycle.
2. **Report upstream and wait for a fix.** The root cause belongs in
   claude-agent-acp / claude-agent-sdk / the `claude` CLI. A minimal
   repro against `agentclientprotocol/claude-agent-acp` referencing
   #551 / #497 would document the symptom and request
   generator-close-on-error semantics (or an SSE idle watchdog
   inside the CLI).

### Do not "fix" this with

- `vim.cmd.redraw()` anywhere (ruled out by `<C-l>` not helping;
  history above shows this path has been tried and reverted).
- Calling `reset_turn_state()` in the auto-continue timer callback
  (speculative workaround, does not touch the stalled bridge
  generator).
- Restarting just the ACPClient subscriber or re-subscribing the
  same session (the stall is *inside* the bridge subprocess —
  subscriber state is irrelevant).
- Adding any state reset in MessageWriter or SessionManager
  (disproven by the two integration tests above).
