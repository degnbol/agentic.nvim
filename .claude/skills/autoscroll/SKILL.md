---
name: autoscroll
description:
  Auto-scroll and attention notifications in the chat widget. Use when changing
  scroll-following, scroll-pause-on-user-scroll, prose pinning, attention
  badges, the WinScrolled handler on the chat buffer, or any new method that
  grows the chat buffer (must call `_auto_scroll` before the write — see the
  discipline rule below). Per-function rationale is in docstrings on
  `MessageWriter:{_is_at_bottom, on_user_scroll, _check_auto_scroll,
  _auto_scroll, _with_modifiable_suppressed}` and `BufHelpers.scroll_down` —
  read those first.
---

# Auto-scroll and attention

User-facing behaviour summary is in `doc/agentic.txt § Auto-scroll`. This
skill is the maintenance map.

## Two-mechanism model

Auto-scroll follows streaming content under two independent gates:

1. **Manual-scroll pause.** When the user scrolls away from the bottom we
   stop following — otherwise auto-scroll would yank them back while they
   read earlier content. The signals that the user wants to follow again are
   reaching the bottom (e.g. `G`) and submitting a prompt
   (`SessionManager:on_user_submit` → `resume_auto_scroll`, which also
   scrolls to the bottom). Queue drains never resume: they are not user
   input.
2. **Prose pin.** A pin caps the viewport at the start of the current
   prose run so the response can be read from the top. The pin is set on
   each prose run and released by the next non-prose write to chat. In
   practice only the *final* prose run's pin sticks — intermediate runs
   are followed by more output that releases the pin and resumes
   following.

The two are independent: if the user scrolls away during a pin, the
manual-scroll pause persists across subsequent pin releases until they
return to the bottom.

## Master switches (`Config.auto_scroll`)

- `enabled` — runtime-toggleable via `keymaps.widget.toggle_auto_scroll`
  (`<localLeader>a`). When false, `BufHelpers.scroll_down` returns early.
  Mutated at runtime, not persisted.
- `pause_on_prose` — when false, no pin (auto-scroll always tracks the
  trailing edge during streaming).
- `bottom_padding` — rows reserved below the last buffer line so
  `virt_line` indicators have breathing room.

## State on `MessageWriter`

| Field | Set by | Cleared by |
|---|---|---|
| `_prose_anchor_line` | First prose chunk of a run, while not paused | Turn boundaries (`write_tool_call_block`, `append_separator`, `write_error_message`, `reset_turn_state`) and user-scroll-away (`on_user_scroll` → `_release_prose_pin`) |
| `_paused_windows[win]` | `on_user_scroll` when that window is not at bottom | `on_user_scroll` when it reaches bottom, and `resume_auto_scroll` (all windows) on a user submit. Survives turn boundaries |
| `_suppress_pin_release` | `_with_modifiable_suppressed` and the deferred scroll callback | Same scope — wraps each synchronous write/scroll |
| `_scroll_verdicts[win]` | `_auto_scroll`, before the write — the frozen per-window scroll *verdict* | Whichever site executes the scroll — `_auto_scroll`'s callback on the non-fold path, `flush_pending_fold_ops` on the fold path. Never on the callback's skip branch (fold op pending), so the verdict rides along to flush or the BufWinEnter retry — except while ops are held for insert mode (`_fold_retry_armed`), where the callback scrolls as usual rather than wait out the insert session |
| `_scroll_callback_queued` | `_auto_scroll` — a callback is queued this tick | The scheduled callback (per-tick coalescing guard) |

These last two are distinct roles, easily conflated:

- `_scroll_verdicts` holds **verdicts, not the toggle.** Each is
  `_check_auto_scroll(win)` frozen *before* the write — so it is not the
  same as `not _paused_windows[win]`. The toggle is one input; the verdict
  also captures whether the viewport was at the trailing edge (which the
  write then invalidates by growing the buffer) and the prose-pin override.
  Neither is recomputable after the write, which is why it is captured and
  stored.
- `_scroll_callback_queued` is the **queue guard** — it only prevents
  double-queuing the per-tick callback. It says nothing about whether the
  scroll will happen.

When a write queues a fold op (closing a long execute body, etc.) the
fold-close owns the scroll. `flush_pending_fold_ops` runs strictly
after treesitter's fold-level recompute, so it scrolls against the
already-*closed* fold height; `_auto_scroll`'s callback skips that tick to
avoid scrolling to the unfolded bottom. Mechanics live in `_scroll_now`,
shared by both sites.

Field docstrings live on the `MessageWriter` class declaration.

## Discipline rule for new write methods

**Any method that grows the chat buffer must call `_auto_scroll(bufnr)`
*before* the write.** Already done in `write_message_chunk`,
`write_tool_call_block`, `update_tool_call_block`, `write_error_message`,
and `write_error_action`. Checking `_is_at_bottom` *after* the write
would see `botline < total_lines` (buffer grew past viewport) and gate
the scroll off — defeating the whole mechanism.

## Flow per streaming chunk (`write_message_chunk`)

1. **Sync** — `_auto_scroll(bufnr)` captures `_scroll_verdicts` from
   `_check_auto_scroll` per window and queues a `vim.schedule` callback.
   `_scroll_scheduled` coalesces multiple calls in the same tick.
2. **Sync** — `_with_modifiable_suppressed` writes the chunk. The
   suppress flag is set across the whole synchronous write, so any
   `WinScrolled` fired by buffer-grow / topline auto-correct is filtered
   out by `on_user_scroll`.
3. **Sync (inside the write)** — pin the start of the prose run if
   `_prose_anchor_line` is nil *and* some window follows.
4. **Async** — the scheduled callback re-asserts suppress, calls
   `BufHelpers.scroll_down(win, max_topline)` per following window, `max_topline =
   _prose_anchor_line + 1` when the pin is set, then clears suppress.

## At-bottom rule (`_is_at_bottom`)

Dual rule depending on focus — see the function's docstring for the
reasoning:

- Chat window is current → `cursor_line >= line_count`. The user can
  move the cursor; staying off the last line means "not at bottom".
- Chat window is not focused → `getwininfo().botline >= line_count`.
  Chat cursor can't move (focus elsewhere) but the user can still
  scroll the chat by hovering with the OS pointer; viewport-reaches-end
  is the only signal.

The chat-widget autocmd that clears the unread badge uses the same dual
rule inline (`chat_widget.lua:_setup_autocommands`). Keep them in sync.

## Attention notifications (`SessionManager:_notify_attention`)

Two firing events:

- **Response complete** — `_notify_attention("[done]")`
- **Permission request** — float shown: `_notify_attention("[?]",
  skip_badge=true)`. Float hidden (no window shows its buffer):
  `_on_permission_hidden` — bell, `[?]` badge, notification.
  Fires only when `add_request` reports an interactive prompt was queued;
  auto-approved requests (read-only, cached, trust-scoped) stay silent.

Behaviour by focus state:

| Chat focus | Scrolled away from bottom | Result |
|---|---|---|
| unfocused | n/a | bell + badge in chat header |
| focused   | yes | badge in chat header (no bell — can't dismiss easily) |
| focused   | no  | no-op |

Badge clears when:

- User reaches the bottom by the at-bottom rule (WinScrolled autocmd on
  the chat buffer in `chat_widget.lua`).
- User submits next prompt (`clear_unread_badge`).
