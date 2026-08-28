# Refactor: one message queue, one gate, one drain rule

Line numbers are against `bbbfe7e`. TODO entries are cited by title, since
`TODO.md` has uncommitted changes.

Land this **before**
[`feature-block-dispatch.md`](feature-block-dispatch.md) — that plan's sequencer
needs the gate predicate defined here. Land
[`bug-auto-continue-discards-queued-prompts.md`](bug-auto-continue-discards-queued-prompts.md)
before either, since this refactor's correctness rests on knowing what the current
behaviour is.

Four mechanisms defer a user message today. Three are ours, one is not:

| Storage | Blocking condition | Drain site |
| --- | --- | --- |
| extmark regions in AgenticInput (`chat_widget.lua:653`) | `is_generating` | `_drain_queue` at turn Stop (`session_manager.lua:1927`) |
| `_pending_input` — a **single** string (`:1583`) | agent not `ready` | `_flush_pending_input` (`:1590`, called `:2084`) |
| `_queued_prompts` — `string[]` (`:1663`) | `_retry_timer` armed | retry callback (`session_recovery.lua:446`), provider switch (`session_manager.lua:2319`) |
| none — SDK-internal | (nothing; we send concurrently) | opaque |

The fourth row is what a mid-turn `<CR>` does: `_handle_input_submit` has no
`is_generating` guard, so the prompt is echoed to chat and the provider holds it.
This is the observed "queued during `/compact`" behaviour — invisible to us,
uncancellable.

Only the first mechanism works. The other two lose messages, and both losses come
from the storage choice, not from rendering:

- **`_pending_input` clobbers.** A bare assignment, so a second pre-ready submit
  overwrites the first. (TODO "Message queuing during resume".)
- **`_queued_prompts` discards everything.** The retry callback clears the list
  before reading it, so auto-continue always sends the literal `"continue"`. See
  the bug note linked above.

## Design

**One storage:** extmark-tagged regions in AgenticInput. Text stays visible and
editable; any edit intersecting a region drops its tag (`_setup_queue`), so a
still-tagged mark has never been edited since tagging.

**One gate**, owned by `SessionManager`, replacing the three scattered checks at
`:1581`, `:1607` and `:1659`:

```
_submit_defer_reason(prompt) -> nil | "in_flight" | "not_ready" | "loading" | "usage_limited"
```

It takes the prompt text because it must return `nil` for locally-handled
commands. `/delete` is intercepted *before* the ready guard by design
(`:1574-1577`), and `/new`, `/clear`, `/context`, `/rename`, `/trust` are handled
locally with no provider round-trip (`:1625-1656`) — all of them work mid-turn
today. A gate that only knew "a submit happened" would tag `/new` and park it.

Reuse the `LOCAL_COMMANDS` table from
[`feature-block-dispatch.md`](feature-block-dispatch.md) § Local command table for
the exemption lookup rather than re-matching patterns here; exact-word lookup also
avoids inheriting the prefix bug in
[`bug-command-interception-prefix-match.md`](bug-command-interception-prefix-match.md).

**Submit hook returns how much it consumed**, not a boolean:

```
on_submit_input(prompt, range?) -> integer|nil consumed_lines   -- nil = nothing dispatched, tag the range
```

A boolean cannot express block dispatch, which consumes *part* of a submit.
`ChatWidget:submit` must therefore defer its buffer mutation until the return value
is known — today it wipes the input at `:438` and only then calls
`on_submit_input` at `:454`. `ChatWidget:_is_generating` and the
`on_query_generating` field (`:46`) are deleted outright.

`_drain_queue()` returns whether it dispatched, so no `has_queued_regions()`
accessor and no check-then-drain window.

**One submit rule:**

| Path | Behaviour |
| --- | --- |
| `<S-CR>` family | always tags, regardless of state |
| `<CR>` family, optional `submit` keymap | dispatch if the gate is clear, tag otherwise |
| `:w` / `:Wq` / `:X` | force-send now, untagging |
| buffer-less (below) | never tagged |

`force` bypasses the **gate**, not the splitter — otherwise the most habitual
submit is the one path that still mis-sends slash commands. All four currently
reach `ChatWidget:submit()` with `send == nil` and are indistinguishable, so the
write commands need an explicit `force` flag. `keymaps.prompt.submit` defaults to
`{}` and `config_default.lua:246-249` already documents that the write commands
submit regardless of it.

**Against `in_flight`, `force` needs a cancel and not just a bypass.** The other
three defer reasons have no running turn to collide with. `_dispatch_turn`
(`session_manager.lua:2045`) unconditionally resets `_tool_call_owner`,
`_open_tasks`, `_subagent_win_opened_this_turn`, `_task_ordinal`, `_next_ordinal`
and `_numbering_latched` (`:2057-2062`), so a second dispatch strands the first
turn's in-flight tool calls, and whichever callback returns first clears
`is_generating` under the other (`:2070`) — the desync the comment at `:2065-2069`
warns about, reached from the other side. So a forced mid-turn submit either
cancels the running turn first or is the one case `force` does not bypass.

Charwise `<CR>` sends (`_send_operator`, `_send_visual`) widen to whole lines when
tagged, since `_queue_line_range` is line-granular. Consistent with the shipped
`<S-CR>`, which already widens charwise motions.

**Buffer-less submits are never tagged, and are never split.** Three producers:
the synthetic `"continue"`; `Config.keymaps.prompts` (default `<localLeader>c` =
`"Continue"`, `chat_widget.lua:1133-1135`); and the public `Agentic.send_prompt`
(`init.lua:378-383`, calls `_handle_input_submit` directly). They have no buffer
range to tag, so they keep a single retained string — `_pending_bufferless_prompt`,
**last-write-wins**, unchanged from today. Two `<localLeader>c` presses before the
session is up still clobber; accepted as a degenerate case rather than motivating a
second queue.

**One drain rule:** dispatch tagged regions when a dispatch-blocking condition
clears *benignly*.

| Condition | Benign-clear edge | Site |
| --- | --- | --- |
| prompt callback outstanding | normal Stop | `session_manager.lua:1927` |
| session not ready | session created | `:2084` |
| session load in flight | load completion | `_do_load_acp_session` — **no site exists** |
| usage-limited | retry timer fires | `session_recovery.lua:446` |

Drain re-checks the gate, covering overlap (a retry armed during a turn that then
ended normally). One predicate, one place, no per-case guards.

The drain currently emits one concatenated turn (`\n\n`-joined, buffer order),
matching `_queued_prompts` semantics. That is wrong for any region containing a
slash command; [`feature-block-dispatch.md`](feature-block-dispatch.md) replaces it
with one block per turn. Stated here so the contract is not inherited silently.

### Normal Stop

The prompt callback already holds everything needed at `:1927`:

```lua
err == nil
    and (response.stopReason == nil or response.stopReason == "end_turn")
```

`agentic.acp.StopReason` (`acp_client.lua:1181-1186`) is
`end_turn | max_tokens | max_turn_requests | refusal | cancelled`. The expression
excludes:

- **`cancelled`** — `<C-c>`. Today `Agentic.stop_generation` (`init.lua:298-309`)
  sends `session/cancel`, the in-flight prompt resolves with
  `stopReason = "cancelled"`, `surface_unexpected_response` treats that as a
  normal terminal reason (`session_recovery.lua:36`), and control falls through to
  the unconditional `_drain_queue()`. So stopping a turn that went sideways
  dispatches the queued message immediately — the risk TODO "Queue message"
  flagged. Excluding `cancelled` fixes it definitionally; no cancelled-turn flag
  is introduced.
- **`refusal` / `max_tokens` / `max_turn_requests`** — the turn did not finish the
  work, and `surface_unexpected_response` already writes these to chat. Launching a
  follow-up onto a truncated state is wrong.
- **any `err`, including `usage_limit`.**

## Gate conditions that are not what they look like

**`is_generating` is not "a turn is in flight".** `Agentic.stop_generation` sets it
false at `init.lua:306` while the prompt is still pending, and `_refresh` clears it
deliberately at `session_manager.lua:640` to recover a stuck state. Gate on it and
a `<CR>` right after `<C-c>` still fires a concurrent `send_prompt`, whose stale
callback then sets `is_generating = false` under the new turn — the desync the
comment at `:1856-1860` warns about. Gate on a prompt-callback-outstanding counter
(set at `:1845`, cleared at `:1861`) instead.

**`_retry_timer` is not "usage-limited".** `offer_auto_continue` returns early when
`Config.auto_continue_on_usage_limit` is false (`session_recovery.lua:362`) or after
`MAX_RETRIES` (`:369-378`), but `respawn_after_usage_limit` still runs
`new_session` either way — so the `:2084` drain finds a clear gate and dispatches
into a still-limited provider, consuming the text from the buffer on a doomed send.
Use an explicit `usage_limited` flag set in the error branch.

That flag needs **three clear edges**, or it deadlocks:

1. **At the retry fire**, before draining. Otherwise the planned
   `if not sm:_drain_queue() then sm:_handle_input_submit("continue") end` hits the
   gate on both branches and sends nothing at all.
2. **At gate-read time when the reset epoch has elapsed.** With
   `auto_continue_on_usage_limit = false` no turn can ever complete normally,
   because every `<CR>` is gated — so a "clear on normal Stop" rule alone leaves
   `<CR>` permanently inert with only `:w` as an escape.
3. **In `_cancel_session`**, so `/new` recovers a wedged session.

## Lifetime and reset semantics

Region storage is buffer-bound where the string queues were manager-bound, so:

- The widget is created once in `SessionManager:new` (`:255`) and destroyed only in
  `SessionManager:destroy` (`:2565`) — strictly 1:1 with the manager, so regions
  have exactly the same lifetime as `_pending_input`.
- The input buffer is scratch with explicit `bufhidden = "hide"`
  (`chat_widget.lua:1459-1465`), so closing the input window or hiding the whole
  widget does not wipe it; extmarks survive hide/reopen. `:edit` reload of Agentic
  buffers is blocked (`edd6639`).
- `NS_QUEUED` is a module-level namespace over buffer-scoped extmarks — allowed by
  `.claude/rules/multi-tabpage.md`. No module-level per-session state is added.

**`_flush_pending_input` does not run on every session-created path.** Three
counter-examples:

- `_do_load_acp_session` (`:2114-2241`) — the shared endpoint of both restore entry
  points (the picker at `session_restore.lua:93`, and `:AgenticResume` via
  `Agentic.resume_query` at `init.lua:358`) — never calls it or `_drain_queue`.
- `new_session`'s create callback skips the `:2084` flush via its early returns at
  `:1984-1988` (error) and `:2002-2005` (`_restoring` / stale epoch).
- `restore_from_history({ reuse_session = true })` (`:2604-2613`) returns without
  `new_session`.

Hence the "session load in flight" row: a new drain site is required. Put it in
`_do_load_acp_session`'s **success branch, after `_restoring = false` (`:2194`) and
after the welcome write** — never at the top of the callback, because the error
branch already reaches a drain via `_fallback_restore_from_local` →
`restore_from_history` → `new_session` → `:2084`, and a top-of-callback drain would
double-send. Note that `set_pending_initial_model` (`:2214`) applies the session's
saved model asynchronously, so a drain firing immediately runs the queued turn on
the provider default model — sequence it after the model applies, or accept that.

`switch_provider` does still reach `:2084` (it trips neither early return), so its
capture-and-resubmit rescue is dead code.

`session_id` is also assigned *before* the `session/load` RPC (`:2159`), so during a
slow load the gate reads clear and a mid-load `<CR>` dispatches into a session being
replayed. Pre-existing; the `loading` gate state fixes it.

**Regions survive session reset.** `widget:clear()` deliberately exempts `input`
(`chat_widget.lua:312-315` — the draft "must survive session resets/swaps") and
nothing clears `NS_QUEUED`, so tagged regions already outlive `/new` in shipped
code. **Keep it that way**: do not add a `cancel_queue()` call to
`_cancel_session`. An earlier draft of this plan added one to mirror
`_pending_input`'s abandon-on-reset, but that would break the `/new\nFresh prompt`
sequence in the sibling plan, and buffer order is what carries the
before-`/new`/after-`/new` distinction. `<S-C-c>` remains the explicit abandon, and
the text is visible in the meantime.

## Deletions

- The three idle→send-now degrades in `ChatWidget:_queue_line`, `:_queue_operator`
  and `:_queue_visual`; `ChatWidget:_is_generating`; the `on_query_generating`
  field (`chat_widget.lua:46`).
- `session_manager.lua:1607` retry check in `_drain_queue`; `:1659-1668` the
  `_queued_prompts` branch; `:2319` + `:2350-2360` the `switch_provider` rescue.
  `:1581-1585` becomes tag-instead-of-stash.
- `session_recovery.lua:276` `sm._queued_prompts = nil`; `:446-450` becomes
  `if not sm:_drain_queue() then sm:_handle_input_submit("continue") end`.
- Dead annotations: `@field _pending_input` (`session_manager.lua:101`),
  `@field _queued_prompts` (`:105`), `@field on_query_generating`
  (`chat_widget.lua:46`), and the `switch_provider` docstring at `:2302-2305`
  ("drains any queued prompts to the new provider").
- Docs: `config_default.lua:260-269` ("When idle they behave exactly as the matching
  send keymap"), and the prompt-keymaps prose in `doc/agentic.txt` ("for dispatch at
  turn end", "dispatch as one prompt at the next turn end", "When idle the queue
  bindings send immediately") — needs "normal turn end" plus the pre-ready, loading
  and usage-limited states.

### Renames

- `_flush_pending_input` → `_dispatch_deferred_prompts`. Not `_on_session_ready`:
  that names one caller's edge, collides with the agent's own `on_ready`
  (`:2102`, `:2117`), and the new load-completion site is not "session ready".
- `_pending_input` → `_pending_bufferless_prompt`, named by role so a reader does
  not assume the pre-ready stash survived.
- The gate is `_submit_defer_reason`, not `_submit_gate` or `_submit_block_reason` —
  "block" is a noun in the sibling plan and in `utils/extmark_block.lua`.

## Tests

Delete `chat_widget.test.lua:1072-1085` ("sends immediately when idle") — it asserts
the three degrades. Its `before_each` at `:1024-1027` and `:1073-1075` set
`on_query_generating` to a boolean-returning function; both break with the new
signature.

**Adapt, do not delete,** `session_manager.test.lua:2203-2226` ("submits pending
text without also draining") — it is the regression test for the double-
`send_prompt` invariant guarded by the comments at `session_manager.lua:1593` and
`session_recovery.lua:454`. `:2149-2201` also stays valid in spirit; the retry case
becomes a gate case. `:1061-1119` (`switch_provider` drain) goes with the rescue
block.

New:

- Gate/tag: submit under each of the four defer reasons → text stays, region
  tagged, nothing sent.
- Gate exemption: `/new` and `/trust` dispatch mid-turn; `/delete` dispatches
  pre-ready.
- Trigger: `end_turn` drains; `cancelled`, `refusal`, `max_tokens` and an error
  response do not.
- Multiple pre-ready submits → separate regions, drained in buffer order (the
  "Message queuing during resume" regression).
- Retry fire with regions present → regions sent as the continuation, no additional
  `"continue"` turn.
- Usage limit with auto-continue disabled → regions stay tagged across the
  respawn's `new_session`, and `<CR>` un-inerts once the reset epoch passes.
- Restore completes with regions tagged → drains once, exactly once; load *failure*
  with regions tagged → also drains exactly once, not twice.
- `/new` with regions tagged → tags retained, regions dispatch into the new session.
- Preview: tag mid-turn → virt_lines below the last row; two more chunks arrive →
  still below the last row, same extmark id. Untag by editing → preview drops that
  region. Drain → no preview extmark and the `##` heading is real buffer text.

## Intended consequences

**`<S-CR>` always queues**, including when idle. The binding's meaning no longer
depends on hidden state.

**A mid-turn prompt never lands inside the stream.** Two cases, and the display
difference between them is the whole point of the gate. A forced submit really was
sent, so it renders at the buffer end where it happened, splitting the streaming
prose run the way a mid-turn notice already does
(`MessageWriter:write_notice`) — the run ends cleanly there because
`write_user_prompt` flushes it.

A tagged region is not sent, and must be **visible below the stream and travel
with it**, not hidden and then revealed at Stop: the reader is looking at the chat
buffer, and a prompt that vanishes from view between `<CR>` and turn end reads as
lost. So the drain also needs a preview:

- Rendered as a virt_lines extmark below the last buffer row, repositioned on each
  chunk rather than deleted and recreated — `StatusIndicator` (`status_indicator.lua`)
  is the working precedent for exactly this placement and update discipline, and
  the two must agree on who sits closest to the text.
- Regenerated from the tagged regions, never stored. It is a *view* of AgenticInput,
  so an edit that drops a region's tag drops it from the preview too, and there is no
  second copy of the text to keep in step.
- Materialised in place at drain: the preview goes away in the same tick
  `write_user_prompt` writes the real `##` heading at the row the preview occupied,
  so the prompt does not appear to move.

This retires `bug-mid-turn-prompt-splits-prose.md` § Open, which floated the
preview as one of two options; it is the chosen one.

**An abnormal Stop parks the queue indefinitely.** Queue while idle with no turn
running, or after a `refusal`, and nothing drains until the user starts a turn that
ends normally. Safe *only because* the text is visible and highlighted in
AgenticInput — the same trigger over the old invisible string queues would silently
eat messages, so the strict trigger and the buffer storage are load-bearing for each
other. Two paths do delete that buffer: `on_hide` destroying a zero-history session
(`session_manager.lua:267-281`, reachable exactly in the pre-ready case) and
`align_provider_for_restore` on a provider-mismatch restore
(`session_restore.lua:71-72`). Both lose `_pending_input` today too, so neither is a
regression.

## Risk to test first

Gating mid-turn `<CR>` folds the `/compact` case in: the message becomes a visible
tagged region draining at compaction's normal Stop. That depends on the provider
ending `/compact` with `end_turn`. If it ends with anything else the queue parks —
recoverable per above, but it is the first thing to check.
