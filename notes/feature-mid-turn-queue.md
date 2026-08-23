# Plan: mid-turn message queue

Implemented in `f170629`. Three decisions here are superseded by
[`refactor-unify-message-queues.md`](refactor-unify-message-queues.md): storage is
unified across all three queues, the idle send-now degrade is dropped, and the
drain trigger narrows to a normal Stop.

## Problem

While the agent is generating (`is_generating == true`), the user often
already knows the next task but doesn't want to interrupt the running
turn. Today a submit mid-turn fires a concurrent `send_prompt`
(`session_manager.lua:1827` has no `is_generating` guard), which is
provider-dependent and not what the user wants. The desired behaviour:
mark a message as *queued* mid-turn, keep refining it if needed, and have
it dispatched automatically at the next Stop (turn completion).

A queued message must stay editable in place, and the whole queue must be
cancellable in one action when the agent takes an unexpected turn and the
Stop becomes a question rather than a completed task.

## Constraints

- **Reuse the existing drain funnel and gate discipline.** Two queues
  already exist (see below); the mid-turn queue shares the submit funnel
  (`_handle_input_submit`) and the "drain only when no gate is active"
  rule, not the storage.
- **Queued text lives in the input buffer**, not a committed string list —
  this is what makes in-place refinement possible. Storage differs from
  the two existing string queues by design.
- **`:w` / full submit stays "send everything now, one prompt."** It is the
  deliberate escape hatch and must not become a stateful multi-press
  splitter (rejected alternative: `:w` flushing queued-then-draft across
  presses — breaks the one-submit-one-turn invariant).
- **Buffer-local, per-tabpage.** One session per tabpage; extmarks are
  buffer-scoped, autocmds and keymaps buffer-local (see
  `.claude/rules/multi-tabpage.md`).

## Existing infrastructure

| Primitive | Location | Role |
| --- | --- | --- |
| `_handle_input_submit` / `_inner` | `session_manager.lua:1562` / `:1589` | Single submit funnel; client-command interception; where the retry-timer gate lives (`:1631`) |
| Stop point | `session_manager.lua:1833` (`is_generating=false`) → `:1865` (`finalize_turn`) | The `send_prompt` completion callback — where the mid-turn queue drains |
| `_pending_input` + `_flush_pending_input` | `session_manager.lua:1571` / `:1579`, flushed at `:2052` | Pre-ready string queue (session not `ready`) |
| `_queued_prompts` | `session_manager.lua:1631`, drained `session_recovery.lua:449` and `session_manager.lua:2323` | Usage-limit string queue; concat with `\n\n` |
| `ChatWidget:submit` | `chat_widget.lua:312` | Whole-buffer submit; clears input at `:333`; calls `on_submit_input` at `:349` |
| Partial-send family | `chat_widget.lua:393` (`_send_line`), `:415` (`_send_operator`), `_send_visual` | Range → immediate send; queue mirrors these deferred |
| `_setup_write_submit` | `chat_widget.lua:581` | `:w` / `:Wq` / `:X` funnel into `submit()` |
| Keymap config | `config_default.lua:243` (`keymaps.prompt`), `:210` (`stop_generation` = `<C-c>`) | Where the new queue/cancel keymaps register |

## Approach decisions

### Queue = deferred partial-send

The queue action mirrors the partial-send keymaps (`send_line` /
`send_operator` / `send_visual`, plus a whole-buffer variant) with
`<S-CR>` bindings. It uses the same range machinery as partial-send but,
instead of sending and deleting the range now, it **tags the range with
an extmark** and leaves the text in place. `<S-CR>` queues only; it is
not a toggle.

Queueing is **line-granular**: the region snaps to whole lines, so the
extmark range *is* the drain range (no separate sub-line range to keep in
sync with a full-line highlight). A single extmark with `hl_group` +
`end_row` = last line + `end_col` = that line's length + `hl_eol = true`
(`api.txt:3249`: continues the highlight past EOL for the rest of the
screen line, "just like for diff and cursorline highlight"). One extmark
covers the whole multi-line range full width — no per-line marks. Not
`line_hl_group`, which only highlights the mark's start line and would
need one mark per line. (`end_col = -1` is rejected — "out of range";
use the last line's byte length.) A charwise motion queues its full
line(s).

Terminal caveat: `<S-CR>` (and any shifted control key) is only
distinguishable from `<CR>` under the kitty keyboard protocol. Works on
kitty + nvim 0.12; document as terminal-dependent.

Idle (not generating) + queue keymap → behave as send-now; there is no
turn to defer to. (Superseded: `<S-CR>` always queues, so the binding's
meaning does not depend on `is_generating`.)

### Storage: buffer-region queue, shared drain

Queued regions are extmark-tagged ranges in the input buffer. On Stop,
`_drain_queue()`:

1. Collects tagged regions **in buffer order** (top-to-bottom = priority),
2. Concatenates their current text with `\n\n`,
3. Deletes the sent regions' text + tags from the input buffer
   (bottom-to-top, mirroring partial-send — a dispatched region leaves the
   buffer, otherwise the next `:w` would re-send it),
4. Funnels through `_handle_input_submit`.

Buffer order carries priority — no separate priority mechanism, no special
`:w` mode.

Drain respects the other gates: if a usage-limit retry timer armed during
the turn, the regions stay tagged and drain when that gate clears, not at
Stop. So the buffer-region queue composes with the two string queues
rather than racing them.

### Auto-unqueue on edit (the key simplifier)

We do **not** track extmark ranges as the user edits inside them. Instead,
editing a queued region drops its tag — a region can never be sent
mid-edit. Two triggers:

- **`on_bytes` (via `nvim_buf_attach`) intersecting a region → untag it.**
  Catch-all: covers normal-mode edits (`dd`, paste, `:s`) and any
  modification regardless of mode or cursor position. `on_bytes` gives the
  exact changed byte range to intersect against each tagged extmark.
- **`InsertEnter` with cursor inside a region → untag that region.** Makes
  "enter insert mode to cancel the one under cursor" literally true —
  entering insert mode changes no bytes, so `on_bytes` alone wouldn't fire.
  The moment the user is poised to edit, the message is no longer a
  committed queued item.

Because any edit untags, the extmark only needs to (a) render the
highlight and (b) be found for drain/cancel; its range need not survive
edits precisely.

### Cancel

- **Cancel-all keymap** (cursor-independent) clears every tag in the input
  buffer, leaving all queued text as ordinary draft in place. This is the
  common "agent went sideways, dump the queue and rewrite" recovery. A
  distinct keymap, not `<C-c>` (which stays `stop_generation`); `<S-C-c>`
  fits for symmetry with `<S-CR>` (same terminal caveat).
- **Cancel one** = edit it (auto-unqueue). No dedicated single-cancel
  keymap and no first/last/nearest ambiguity to design.
- A future quickfix-like window for selective multi-cancel is the richer
  front-end; same underlying data, defer it.

### `:w` semantics

`:w` / `:Wq` / `:X` unqueue everything and submit the whole buffer as one
prompt, now (current behaviour, single turn). It is the "I mean it now"
override.

## Implementation outline

1. **Extmark namespace + highlight group.** New `theme.lua` group for the
   queued-region highlight (subtle background); update `README.md` per the
   theme convention. Applied full-width via a single extmark with
   `hl_group` + `end_row`/`end_col = -1` + `hl_eol = true` — covers the
   whole multi-line range, one mark, no per-line marks. Namespace created
   module-level (global namespaces are fine; extmarks are buffer-scoped).
2. **Queue action in `ChatWidget`.** Factor the range extraction shared by
   `_send_line` / `_send_operator` / `_send_visual` so a `queue` variant
   reuses it: instead of `submit({text, delete_range})`, tag the range with
   the highlight extmark and record it. Register `<S-CR>` bindings under a
   new `keymaps.prompt.queue*` group in `config_default.lua`.
3. **Auto-unqueue.** `nvim_buf_attach` `on_bytes` on the input buffer →
   drop tags whose range the change intersects. Buffer-local `InsertEnter`
   autocmd → drop the tag under the cursor. Both live with the widget's
   input-buffer setup; ensure cleanup on widget destroy.
4. **Drain on Stop.** In the `send_prompt` callback
   (`session_manager.lua:1833`+, after `is_generating=false`), call
   `_drain_queue()` which gathers tagged regions from the input buffer in
   order, concats `\n\n`, submits, clears tags — guarded by the same
   no-active-gate check the other queues use.
5. **Gate composition.** If a gate (retry timer / not-ready) is active at
   Stop, skip the drain; hook the existing gate-clear sites
   (`_flush_pending_input`, the retry-timer callback) to also attempt the
   buffer-region drain.
6. **Cancel-all keymap.** New `keymaps.widget` (or `keymaps.prompt`) entry;
   handler clears all tags in the input buffer. Default `<S-C-c>`.
7. **Tests.** Widget-level: queue a range → tag present; edit inside →
   untag; InsertEnter inside → untag; cancel-all → all tags cleared.
   Session-level: queue mid-turn → drains at Stop in buffer order; queue +
   retry-timer active at Stop → drains at timer, not Stop.
8. **Docs.** User-facing summary in `doc/agentic.txt` (keymaps + behaviour,
   no internals). Document the `<S-CR>`/`<S-C-c>` terminal-protocol caveat.

## Deferred / out of scope

- **Standalone slash commands in a queued blob.** A queued region may
  contain a client-intercepted command (`/trust repo`) or a provider
  command needing its own turn (`/compact`). Interception in
  `_handle_input_submit_inner` is anchored at the start of the whole text
  (`^/…`), so a concatenated blob won't match. The proper fix is a
  **line/block-oriented dispatch pass** that peels standalone command
  blocks out of any submitted text and runs them in order — this benefits
  every submit path, not just the queue. Same root cause as TODO
  "Command queuing" (`/compact\nContinue`). MVP concats as-is and documents
  the limitation. Multi-line commands mean the dispatch must be
  block-oriented, not single-line.
- **Full storage unification.** The two string queues (`_pending_input`,
  `_queued_prompts`) could also become buffer-region-based, but they carry
  committed-text semantics and work today. Not worth folding in now.
  (Superseded — planned in
  [`refactor-unify-message-queues.md`](refactor-unify-message-queues.md); their
  committed-text semantics are the cause of two open TODO bugs.)
- **`:w` as a priority flush** (queued-then-draft across presses) —
  rejected; breaks the one-submit-one-turn invariant. Priority comes from
  buffer order instead.

## Related TODO entries

- Feature idea "Queue message" (`TODO.md`) — this plan realises it,
  including the risk it flags (Stop-hook question buried by an auto-sent
  queued message; mitigated by the message staying visible/editable in
  input and one-key cancel-all).
- "Message queuing during resume" — the shared gate discipline covers the
  not-ready case.
- "Command queuing" (`/compact\nContinue`) — same root cause as the
  deferred dispatch pass above; fix them together.
