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

The multi-hour idle between `_offer_auto_continue` scheduling the timer and
the timer firing is a strong trigger. Reproducibility gated by the once-a-day
reset cycle, so live debugging is expensive.

### Code-path asymmetry (useful for narrowing)

`agent_message_chunk` and `tool_call` / `tool_call_update` route through
`ACPClient:__handle_session_update` (`lua/agentic/acp/acp_client.lua`).
Permission prompts route through `ACPClient:__handle_request_permission`
(separate top-level RPC method). Both eventually `vim.schedule` on the
subscriber callback, and both look up the same `self.subscribers[session_id]`.

Any hypothesis that depends on `vim.schedule` as a whole not firing, or on
the subscriber table being empty, is falsified by "permission prompts work".

Any new hypothesis MUST explain why `__handle_request_permission`'s path
works while the `__handle_tool_call` / `__handle_tool_call_update` / `else →
__with_subscriber` paths inside `__handle_session_update` do not.

### Do not "fix" this with

- `vim.cmd.redraw()` anywhere (ruled out by `<C-l>` not helping; history
  above shows this path has been tried and reverted).
- Calling `reset_turn_state()` in the auto-continue timer callback
  (speculative workaround, not a root-cause fix).
- Restarting the subscriber or the agent (blast radius too large for a
  symptom whose real cause in this context is unidentified).
