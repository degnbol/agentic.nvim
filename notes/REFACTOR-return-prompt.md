# Plan: one draft return for a returned prompt
Status: reviewed spec

## Relevant files
- `lua/agentic/session_recovery.lua` — `restore_refused_prompt`,
  `requeue_limited_prompt`, `return_limited_prompt`, `reattach_context`
- `lua/agentic/session_manager.lua` — `agentic.ReturnReason`,
  `agentic.OnReturned`, the `on_returned` closure in
  `_handle_input_submit_inner`, the `return_prompt` closure in
  `_subagents_host`, `_queue_input`, `_continue_mark`
- `lua/agentic/subagents.lua` — `agentic.Subagents.Host.return_prompt`; its
  caller in `Subagents:_relay_to_agent`
- `lua/agentic/ui/input_dispatch.lua` — `InputDispatch:prepend_draft`,
  `cancel_queue`, `queued_block_count`
- `lua/agentic/utils/buf_helpers.lua` — `BufHelpers.prepend_draft`
- Tests: `lua/agentic/session_recovery.test.lua` (`requeue_limited_prompt`,
  `return_limited_prompt`, `restore_refused_prompt`),
  `lua/agentic/session_manager.test.lua` (the `restore_stub`,
  `requeue_stub`, `draft_stub` cases)
- Skills: `implement`

## Background
A returned prompt goes back to the user in one of three ways:
- **Refusal**: every queued block becomes draft, the text goes on top as a
  draft, and two error-action lines go to the chat.
- **Usage limit, held**: the text becomes the first queued region.
- **Usage limit, not held**: the text goes on top as a draft and the queue
  stays.

Each way is its own function (`restore_refused_prompt`,
`requeue_limited_prompt`, `return_limited_prompt`). Both callers choose
between them with `(reason, held)`, the arguments of `agentic.OnReturned`:
- `_handle_input_submit_inner` uses all three.
- The subagent host's `return_prompt` ignores `held` and never requeues.
  That is correct: the text is the user's message to a subagent, so as a
  main-agent prompt it would go to the wrong agent.

The two draft-on-top paths differ:
- `restore_refused_prompt` writes `BufHelpers.prepend_draft` straight into
  the input. That is safe only because it ran `cancel_queue` first, so no
  region can be untagged.
- `return_limited_prompt` goes through `InputDispatch:prepend_draft`, whose
  `_draining` guard keeps the regions tagged. It uses `BufHelpers` only for
  a subagent's input `bufnr`.

So "put a draft on top" exists twice. Requeueing is a different operation:
it adds a queued region with the `_continue_mark` rule and never drafts.
Only `_handle_input_submit_inner` can requeue, so it stays its own function.

## Changes
### `session_recovery.lua`
- New `M.return_prompt(sm, text, consumed, reason, bufnr)`. It replaces
  `restore_refused_prompt` and `return_limited_prompt` and returns nothing.
  - `reason`: `agentic.ReturnReason`.
  - `bufnr`: a subagent's input, nil for the session's input.
  - Body: the `destroyed` guard. Then:
    - `"refusal"`: draft the queue as today, put the draft, write the two
      lines.
    - `"usage_limit"`: put the draft.
    - `reattach_context` runs last.
- `M.requeue_limited_prompt(sm, text, consumed)` stays as it is.
- New local `put_draft(sm, text, bufnr)`:
  - With `bufnr`: `BufHelpers.prepend_draft(bufnr, text)`.
  - Otherwise: `sm.widget:panel_buf("input")` (making the input makes its
    dispatch), then `sm.widget.input_dispatch:prepend_draft(text)`.
  - The refusal path uses it too.
  - `panel_buf` returns nil only after `ChatWidget:destroy`, whose one
    caller is `SessionManager:destroy`. That sets `destroyed` first, which
    the guard checks. So the change from today's error to the dispatch's
    no-op on a missing input cannot be reached.
- Module header comment: replace the "Return of a refused prompt" bullet
  with one for the return of a prompt as a draft.
- Delete `restore_refused_prompt` and `return_limited_prompt`.

### `session_manager.lua`
- `_handle_input_submit_inner`:
  `if reason == "usage_limit" and held then Recovery.requeue_limited_prompt(self, input_text, consumed) else Recovery.return_prompt(self, input_text, consumed, reason) end`.
  The "No lift to wait for." comment goes on the `else`.
- `_subagents_host().return_prompt`:
  `Recovery.return_prompt(self, text, { selections = {}, files = {}, diagnostics = {} }, reason, bufnr)`.

### Tests
Change the tests before the code.
- `session_recovery.test.lua`:
  - The `restore_refused_prompt` and `return_limited_prompt` describes
    become `return_prompt` cases with `"refusal"` and `"usage_limit"`. The
    existing assertions stay.
  - The `requeue_limited_prompt` describe stays.
  - New case: `"usage_limit"` with a `bufnr` drafts into `bufnr` and
    leaves the queue alone.
- `session_manager.test.lua`:
  - Keep `requeue_stub`.
  - Replace `restore_stub` and `draft_stub` with one
    `spy.stub(Recovery, "return_prompt")`, and assert its `reason`
    argument.

## Expected outcome
No change in what the user sees. Both draft returns go through one function
and one draft helper. A draft on top of the session's input always goes
through `InputDispatch`.

## Non-goals
- Whether a refused subagent message should draft the main input's queue
  and write the main chat's error-action lines, as it does today.

## Open questions
None.
