---
name: follow
description:
  Maintenance map for follow (the chat view tracking streamed output, also
  called auto-scroll — per-window user control vs following, the prose pin,
  scroll-to-bottom) and attention signals (terminal bell, `[idle]`/`[?]` header
  badges). Use when editing `_schedule_follow`, `on_view_change`,
  `_own_change`, `BufHelpers.scroll_down`, `_notify_attention`, or adding any
  method that writes to the chat buffer (it must call `_schedule_follow`).
---

# Follow and attention

User-facing behaviour: `:h agentic-follow`, `:h agentic-attention`.
Per-function rationale is in the docstrings and `@field` docs of
`MessageWriter` and on `BufHelpers.scroll_down` — read those first.

## Model

Each window showing the chat is in one of two modes:

1. **User control** (`_user_controlled[win]`). Writes do not scroll it.
2. **Following.** Targets, first match wins:
   1. **Prose pin** — the start of the current prose run.
   2. **Bottom** — the trailing edge of the stream.

The user's motion changes the mode, never the window's position:
`on_view_change` reads it as the difference from the last view seen
(`_views[win]`), for keys and mouse alike: rows of text from the topline to
the end, and the cursor line. Up takes control; the cursor on the last line
(or a closed fold ending there), or the view down with the last line in
view, hands it back. Besides, `go_to_bottom` (`<localLeader>G`) and
`resume_follow` (submit) hand windows back, and a pin
that held the view short of the last line (`_pin_held`) puts its window in
user control when it releases.

## Write path

- Any method that writes to the chat buffer calls `_schedule_follow`, which
  owes a scroll; it goes to every window not in user control when it runs.
- Every write, scroll and fold op runs inside `_own_change`, which records
  the view it leaves, so the WinScrolled/CursorMoved it causes later is not a
  difference.
- The scheduled scroll goes `_scroll_followers` → `_scroll` →
  `BufHelpers.scroll_down`. A pending fold op hands the scroll to
  `flush_pending_fold_ops` instead, except while ops are held for insert
  mode.

## Attention

`SessionManager:_notify_attention` badges `[idle]` only when no chat window
follows (`any_following`). Following again does not clear it; a submit does.
