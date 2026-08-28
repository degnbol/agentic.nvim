# Bug: a forced mid-turn submit splits the streaming prose run

Unit 4 of 5, independent of the other four. Overview:
[`PLAN-gutter-identity.md`](PLAN-gutter-identity.md).

## Observed

Submitting while the agent is generating writes the prompt into the chat at the
current buffer end — inside the prose run being streamed. The `##` heading lands
mid-paragraph, so the run renders as two paragraphs with a prompt block wedged
between, and the `##` closes the previous prompt's section, so the rest of the
turn's output is filed under a prompt that has not been answered yet.

## Most of this is already fixed on paper

`refactor-unify-message-queues.md` § "One submit rule" makes a `<CR>`-family
submit **tag instead of dispatching** whenever the gate is closed, and its
§ Deletions removes the idle→send-now degrades in `ChatWidget:_queue_line` /
`_queue_operator` / `_queue_visual`. Once that lands there is no mid-turn
`write_user_prompt` on the ordinary path at all.

What survives is the deliberate escape hatch: `:w` / `:Wq` / `:X` are specified
as "force-send now, untagging". So the remaining scope is **the forced submit** —
and, until that refactor lands, every plain `<CR>` submit too, since
`_handle_input_submit` has no `is_generating` guard today.

That narrowing matters for the fix: a forced submit is an explicit "now", so
hiding it until the turn ends is a worse answer here than it would be for an
accidental one.

## The client-side half is not provider-dependent

A mid-turn submit reaches `_dispatch_turn` (`session_manager.lua:1839`), which
resets `_tool_call_owner`, `_open_tasks`, `_subagent_win_opened_this_turn`,
`_task_ordinal`, `_next_ordinal` and `_numbering_latched` (`:1867-1875`) *while
the first turn is still in flight*, and registers a second Stop callback that will
set `is_generating = false` under the first. Whether the provider accepts a
concurrent `session/prompt` is its own question; this clobbering is ours. The fix
belongs with the gate work in `refactor-unify-message-queues.md`, not with the
rendering.

## Display: deferral is right here, unlike for notices

This is the opposite case to a command notice (see `MessageWriter:write_notice`,
whose docstring carries the heading-level rule). A notice takes effect the
instant it is issued, so its honest position is where it happened. A prompt is not acted on until the current turn completes — so showing
it at the turn boundary is where the agent actually receives it.

The Stop handler in `send_prompt`'s completion callback already sequences
`finalize_turn` (`session_manager.lua:1936`) → `set_turn_usage` (`:1937`) →
`scroll_to_bottom` → `_drain_queue` (`:1982`). Two constraints: flush **after**
`set_turn_usage`, or the prompt lands between the prose and that turn's usage
footer; and on the `retrying` branch defer again rather than flushing, for the
same reason queued regions do — a retry turn reaches its own Stop.

## Prior art for "render at the bottom while content grows"

`StatusIndicator` is a virt_lines extmark pinned to the buffer bottom,
repositioned on every chunk rather than deleted and recreated
(`status_indicator.lua:1`, `:40`). Virtual text, so it is a precedent for the
*placement*, not a mechanism that yields real buffer text — but it is the obvious
basis if a forced prompt should be visible before the turn ends.

## Open

- Is this note still wanted once `refactor-unify-message-queues.md` lands, or does
  the forced-submit residue fold into that note?
- Should a deferred prompt be visible while it waits (virt_lines preview at the
  bottom, materialised as buffer text at Stop), or invisible until flushed?
- Does the same deferral apply to the `<S-CR>` queue's own display, or does the
  input-buffer `QUEUED_REGION` highlight already cover that case?
