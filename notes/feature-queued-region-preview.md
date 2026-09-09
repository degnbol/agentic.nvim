# Feature: show queued regions below the stream

The gate and the queue landed in `19fa6d6`; this is the one piece of
`refactor-unify-message-queues.md` left unbuilt.

## Problem

A deferred submit is tagged in AgenticInput and nowhere else. The reader is
looking at the **chat** buffer while a turn streams, so a prompt they just
pressed `<CR>` on is off-screen until it dispatches — it reads as lost, which is
the failure the visible-storage design was meant to remove.

Two submits make this worse than it sounds:

- A whole-buffer `<CR>` tags every line. The next keystroke anywhere in the
  buffer untags all of it (`_setup_queue`'s `on_bytes`), so a prompt the user
  believes is pending silently becomes ordinary draft and never dispatches.
  `<S-CR>` has the same rule, but there the user tagged deliberately.
- `Agentic.send_prompt` and `Config.keymaps.prompts` have no range to tag at
  all. They retain to `_pending_bufferless_prompt`, last-write-wins. Today they
  write a one-line notice naming the defer reason; that is a stopgap, not a view.

## Design

Rendered as a virt_lines extmark below the last chat row, repositioned on each
chunk rather than deleted and recreated. `StatusIndicator` (`status_indicator.lua`)
is the working precedent for exactly this placement and update discipline.

**Open: which of the two sits closest to the text.** `StatusIndicator` sets no
`priority` on its extmark (`status_indicator.lua:95`), so today the order would
fall out of extmark id. Decide it explicitly and set both.

Regenerated from the tagged regions, never stored — it is a *view* of
AgenticInput, so an edit that drops a region's tag drops it from the preview too
and there is no second copy to keep in step.

Materialised in place at drain: the preview goes away in the same tick
`write_user_prompt` writes the real `##` heading at the row it occupied, so the
prompt does not appear to move.

This retires `bug-mid-turn-prompt-splits-prose.md` § Open, which floated the
preview as one of two options; it is the chosen one.

## Why the queue is safe without it, for now

**An abnormal Stop parks the queue indefinitely.** Queue while idle with no turn
running, or after a `refusal`, and nothing drains until a turn ends normally.
That is tolerable only because the text is visible and highlighted in
AgenticInput — the same trigger over the old invisible string queues would
silently eat messages, so the strict trigger and the buffer storage are
load-bearing for each other.

Two paths delete that buffer: `on_hide` destroying a zero-history session
(reachable exactly in the pre-ready case) and `align_provider_for_restore` on a
provider-mismatch restore (`session_restore.lua:71-72`). Both lost
`_pending_input` before the refactor too, so neither is a regression.

## Tests

- Tag mid-turn → virt_lines below the last row; two more chunks arrive → still
  below the last row, same extmark id.
- Untag by editing → preview drops that region.
- Drain → no preview extmark, and the `##` heading is real buffer text.

## Risk to check first

Gating mid-turn `<CR>` folds the `/compact` case in: the message becomes a
visible tagged region draining at compaction's normal Stop. That depends on the
provider ending `/compact` with `end_turn`. If it ends with anything else the
queue parks — recoverable, but it is the first thing to measure.
