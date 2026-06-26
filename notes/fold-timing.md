# Fold-vs-auto-scroll timing bug

## Symptom

When a new `execute` tool call lands with long stdout, the body is rendered
fenced as `console-fold` and folded closed to avoid chat clutter. But the
chat view scrolls *too far down* — as if following the unfolded console
output. The view ends up anchored past the real (folded) bottom, showing
empty space below the content. It happens too fast to see the intermediate
state; the eye only catches the final wrong position.

The same path applies to any folded body (search results, sidecar
markdown), but execute stdout is where it bites because it's both long and
frequent.

## Root cause: scheduling order, not fold-unawareness

`BufHelpers.scroll_down` *is* fold-aware — it measures with
`nvim_win_text_height`, which accounts for closed folds
(`utils/buf_helpers.lua:180-208`). The bug is that the scroll runs **before
the fold is actually closed**, so the fold-aware height calc measures a
still-*open* fold and scrolls to the unfolded bottom.

Both the scroll and the fold-close are deferred with `vim.schedule`, and
`vim.schedule` callbacks run FIFO. In `MessageWriter:write_tool_call_block`
(and identically in `update_tool_call_block`):

1. `message_writer.lua:946` — `self:_auto_scroll(self.bufnr)` is called
   **before** the write. The at-bottom *decision* is captured synchronously
   (correctly — see below), but the actual `scroll_down` execution is queued
   via `vim.schedule` (`_auto_scroll`, `:787`). → **callback A**, queued first.
2. The synchronous write runs (`_append_lines` → `nvim_buf_set_lines`). The
   buffer edit makes treesitter queue its own fold-level recompute. →
   **callback TS**, queued second.
3. `message_writer.lua:989` — `self:_close_fold(...)` → `_queue_fold` →
   `vim.schedule(flush_pending_fold_ops)`. → **callback B**, queued third.

FIFO drain order: **A, TS, B**.

So **A** (scroll) fires while the fold is still open. `height_to_last`
measures the full unfolded console height, `scroll_down` picks a
`natural_target` deep down (`buf_helpers.lua:189-208`) and parks the cursor
on the real last line (`:220-221`). Then **B** collapses the fold
(`flush_pending_fold_ops:907-915`), shrinking the rendered height — but
nothing re-scrolls. The viewport is left where A put it.

For execute bodies `fold_open` is never set
(`tool_call_renderer.lua:482-486`) → always `_close_fold`, so this fires
every time long stdout arrives.

## Why the obvious fixes don't work

**Can't just swap two statements.** These aren't two synchronous operations
to reorder — they're three `vim.schedule` hops, and the fold-close has a
hard dependency the scroll doesn't:

- The foldclose (B) **must** run after the treesitter recompute (TS) or it
  hits **E490 (no fold found)**. This is documented and verified in the
  `_queue_fold` docstring (`message_writer.lua:827-841`). That's the whole
  reason `_close_fold` is itself deferred.
- So foldclose is necessarily the *latest* of the three hops, and the scroll
  has to come after it.

**Can't make the foldclose synchronous.** Same E490 race — an immediate
`:foldclose` right after the buffer edit races the TS fold-level recompute.

**Can't move the scroll's decision after the write.** `_auto_scroll`
captures `_should_auto_scroll` *before* the write deliberately: a post-write
at-bottom check would see `botline < total_lines` (the write just grew the
buffer past the viewport) and gate the scroll off. See the docstring at
`message_writer.lua:771-776`. So the *decision* must stay before the write;
only the *execution* can move.

Conclusion: "fix the ordering" means making the scroll **execution** wait
until after callback B — a re-schedule/dependency, not a line swap.

## Solution: the fold-close owns the single scroll

Keep the synchronous at-bottom verdict capture in `_auto_scroll`
(`:778-780`) — unchanged. Move only the scroll *execution* so it is driven
by the fold-close instead of racing it:

1. Extract the scroll body (`max_topline` calc + suppress wrap +
   `scroll_down`, `:795-806`) into a `_scroll_now(bufnr)` helper. It
   **saves and restores** `_suppress_pin_release` (instead of hardcoding it
   back to `false`) so it nests inside `flush_pending_fold_ops`'s existing
   suppress wrap.
2. `_auto_scroll`'s scheduled callback scrolls via `_scroll_now` **only when
   `#self._pending_fold_ops == 0`**. When fold ops are pending it skips —
   the fold-close will scroll.
3. `flush_pending_fold_ops`, after closing the folds, calls `_scroll_now`
   when the verdict still holds. Because flush runs strictly after the
   treesitter recompute (callback B is by construction the latest hop), the
   scroll measures the already-closed fold. No re-defer, no FIFO reasoning —
   "scroll after fold-close" is a direct call from the thing that closes the
   fold.
4. The verdict `_should_auto_scroll` is cleared by whichever site executes
   the scroll: the callback on the non-fold path, flush on the fold path.
   **Never** cleared in the skip branch — a verdict whose flush deferred to
   the BufWinEnter retry (no window yet, `:891`) then rides along with its
   pending fold and lands together when the window reappears.

This keeps prose untouched: pure prose queues no fold ops, so the callback
scrolls exactly as today and flush early-returns (`:883`). When prose and a
fold coalesce in one tick (`_scroll_callback_queued` collapses them into a
single callback), the callback sees the pending fold op and skips, so flush
does the one fold-aware scroll covering both.

### Execution-time pause re-check

The verdict is captured before the write, and the scroll can now defer as
far as the BufWinEnter retry — a wider window for the user to scroll away
mid-gap. So `_scroll_now`'s callers gate on the **live**
`not self._auto_scroll_paused` in addition to the captured verdict. The
verdict supplies the frozen pre-write at-bottom snapshot; the live toggle
catches a scroll-away during the gap. They guard different instants
(capture-time vs execution-time) — keep both.

### Why not the alternatives

- **Re-defer the scroll inside `_auto_scroll`'s own callback** (re-`vim.schedule`
  past pending fold ops). Fires exactly once too, but expresses the
  dependency by self-rescheduling and reasoning about FIFO queue position;
  carries open questions about `_scroll_callback_queued` coalescing across
  the extra tick. The flush-owned call expresses the same ordering directly.
- **Re-assert the scroll at the tail of flush after an independent first
  scroll.** Scrolls *twice* — to the wrong place, then corrects — and relies
  on both callbacks draining before the next redraw to hide the wrong frame.
  Tried and reverted 2026-06-26: validated green but the open-stdout frame
  can paint. The flush-owned scroll never runs an early wrong scroll, so that
  frame never exists.

### Naming

`_scroll_scheduled` → `_scroll_callback_queued`: it guards against
double-queuing the per-tick callback; "scheduled" reads as a synonym of the
verdict. The verdict stays `_should_auto_scroll` — it is **not**
`not _auto_scroll_paused`. The toggle is one input; the verdict also freezes
whether the viewport was at the trailing edge before the write (and the
prose-pin override, `_check_auto_scroll:742`), neither of which the toggle
carries and neither recomputable after the write grows the buffer.

When implementing, fold the matching edits into the `autoscroll` skill state
table (the `_should_auto_scroll` "Cleared by" row gains the flush path; the
rename) and draw the verdict-vs-toggle-vs-queue-guard line there, keeping the
deep detail in the field docstrings the skill already points at.

## Constraints any fix must preserve

- At-bottom *decision* captured before the write (`:771-776`).
- Gate on `_check_auto_scroll` so a paused / scrolled-away user is never
  yanked (`_auto_scroll_paused`, prose pin — see the `autoscroll` skill).
- Wrap any self-driven `winrestview`/`scroll_down` in `_suppress_pin_release`
  so the resulting synchronous `WinScrolled` isn't mistaken for a user
  scroll (`on_user_scroll`).
- Don't add a scroll on the non-fold path — plain prose chunks never queue
  fold ops, and `flush_pending_fold_ops` early-returns when nothing is
  pending (`:883`), so keep that path untouched.

## Key references

- `lua/agentic/ui/message_writer.lua`
  - `_auto_scroll` `:777` — decision capture + deferred scroll
  - `_queue_fold` / `_close_fold` / `_open_fold` `:827-872` — E490 race rationale
  - `flush_pending_fold_ops` `:882` — the post-TS foldclose
  - `write_tool_call_block` `:924`, `update_tool_call_block` `:1034` — call order
- `lua/agentic/utils/buf_helpers.lua:180-208` — fold-aware `scroll_down`
- `lua/agentic/ui/tool_call_renderer.lua:482-486` — execute body, `console-fold`, no `fold_open`
- Skills: `autoscroll` (two-mechanism model, suppress flag), `rendering`
  (fold info-strings, `folds.scm`, deferred fold-close)
