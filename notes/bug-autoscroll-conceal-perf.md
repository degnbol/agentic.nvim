# Perf bug: O(n²) main-thread stall (auto-scroll × conceal) during streaming render

A separate, confirmed bug — distinct from the zsh-parser crash in
`bug-zsh-parser-hang.md`. This one makes long chats stutter and, in the extreme,
could freeze the UI; it does not match the crash's profile (short/new sessions,
tiny output) and is not its cause.

## Summary

The chat window's auto-scroll (`BufHelpers.scroll_down`) recomputes the rendered
height of a **near-whole-buffer range** via `nvim_win_text_height` on **every
render update**. Because the chat window runs at `conceallevel=2`, each height
computation invokes the treesitter `conceal_line` decoration provider **once per
line**, and that provider runs a **treesitter query per line**. So a single
`scroll_down` costs `O(lines) × treesitter-query`, times `~log(lines)`
binary-search iterations, and it fires on every streaming `tool_call_update`.
Net cost grows like **O(n²·log n)** in buffer size.

For a small buffer this is a sub-second stutter. For a long chat it grows into
visible lag on every streamed update.

## Evidence

### Live profile (the smoking gun)

Sampled the live host nvim (the process owning `AGENTIC_SOCK`) with macOS
`sample` while streaming ~300 lines of tool output into a long chat. Of ~4636
active main-thread samples, **4513** were in this single call chain:

```
main → state_enter → normal_execute → nv_event → state_handle_k_event
  → nlua_schedule_event → lua_pcall
    → nvim_win_text_height → win_text_height → plines_win_nofill
      → decor_conceal_line → decor_providers_invoke_conceal_line
        → decor_provider_invoke → nlua_call_ref_ctx (Lua conceal_line callback)
          → ts_query_cursor_next_match        (in libtree-sitter)
            → ts_query_cursor__advance
            → ts_tree_cursor_goto_first_child_internal ...
```

Hot-symbol tally over the same sample (main-thread region):

```
1648 luajit
  44 ts_query_cursor__advance
  28 decor_
  22 ts_parser_parse
  18 ts_tree_cursor_goto_first_child_internal
  15 lua_pcall
  13 ts_tree_cursor_child_iterator_next
  11 nlua_call_ref_ctx
  10 ts_tree_cursor_goto_sibling_internal
  ...
```

Interpretation: `nvim_win_text_height` (called from Lua, via a scheduled event)
dominates the main thread, and its cost is entirely inside the per-line
`conceal_line` provider running treesitter queries.

A control sample of the same processes while **idle** showed the main thread
100% in `uv__io_poll`/`kevent` (normal event-loop wait) — the cost only appears
during render/scroll.

### The code

`lua/agentic/utils/buf_helpers.lua`, `BufHelpers.scroll_down(winid, max_topline)`
(starts line 154):

- Line ~190: `height_to_last(1)` — a **full-buffer** height measurement
  (`start_row = 0, end_row = last_line - 1`) on every call, before the search.
- Lines ~193–201: binary search over topline `t`, each iteration calling
  `nvim_win_text_height(winid, { start_row = t-1, end_row = last_line-1 })`.
- Lines ~227–239: a **second** binary search, same per-iteration height calls.

```lua
local function height_to_last(t)
    return vim.api.nvim_win_text_height(winid, {
        start_row = t - 1,
        end_row = last_line - 1,
    }).all
end
```

Each `nvim_win_text_height` over `[t .. last_line]` is O(range) because height
depends on conceal (concealed lines can be zero-height), forcing per-line
conceal-provider evaluation across the whole range.

### The multiplier: conceallevel

`lua/agentic/ui/widget_layout.lua:199-200` sets the chat window to
`conceallevel = 2`, `concealcursor = "n"`. This activates the treesitter
markdown conceal decoration provider on the chat buffer. Without conceal,
`nvim_win_text_height` would be cheap; with it, every measured line runs a
treesitter query.

### Call frequency (why it's quadratic, not linear)

`scroll_down` is invoked on essentially every render/update:

- `lua/agentic/ui/message_writer.lua:820` — `scroll_down` (chat win)
- `lua/agentic/ui/message_writer.lua:845` — `scroll_down` (chat win, with `max_topline`)
- `lua/agentic/ui/chat_widget.lua:337` — `scroll_down` (chat win)
- `lua/agentic/ui/chat_widget.lua:500` — `scroll_down` (winid)

Streaming tool output produces many `tool_call_update`s, each re-rendering and
re-scrolling. Per update: O(n·log n) treesitter queries. Across the whole
stream: O(n²·log n).

## Reproduction

- Open a chat and let it grow (or resume a long session), then have the agent
  run a command that streams a few hundred lines of stdout. The window stutters,
  worsening as the buffer grows. The stall scales with buffer size, so it is most
  visible in long chats.

To profile a live instance without perturbing it (macOS):

```
sample <nvim-pid> 20 -f /tmp/nvim-sample.txt     # nvim-pid = owner of $AGENTIC_SOCK
# then look for nvim_win_text_height / decor_conceal_line / ts_query_cursor on the main thread
```

`sample` does not stop the process.

## Fix (proposed)

nvim 0.12 added a `max_height` opt to `nvim_win_text_height` (`api.txt`,
`news.txt`): the line walk stops once the accumulated height reaches the cap —
"Useful to e.g. limit the height to the window height, avoiding unnecessary
work." Every height call in `scroll_down` is only ever compared against a
screen-sized threshold, so capping at `threshold + 1` preserves every
comparison (capped heights also stay monotonic, so both binary searches are
untouched) while making each call O(winheight) instead of O(buffer). Fold /
wrap / conceal awareness is kept for free — same API, same semantics, and
`max_topline` clamping is unchanged.

The edit, confined to `BufHelpers.scroll_down`:

1. **Cap both height calls.**

   ```lua
   local function height_to_last(t)
       return vim.api.nvim_win_text_height(winid, {
           start_row = t - 1,
           end_row = last_line - 1,
           max_height = effective_winheight + 1,
       }).all
   end
   ```

   Likewise `max_height = cursor_height + 1` in the second (cursor-placement)
   search. The two searches have opposite monotonicity — the first has a fixed
   end and moving start (height non-increasing in `t`), the second a fixed start
   and moving end (height non-decreasing in `mid`) — but the cap is
   comparison-preserving for both. `max_height` stops accumulating once the
   running height reaches the cap, counting the boundary line whole (`api.txt`:
   "Don't add the height of lines below the row for which this height is
   reached"), so the returned `all` is *not* `min(uncapped, cap)` — it can
   overshoot the cap by that last line. The `> threshold` test is preserved
   anyway: with `cap = threshold + 1`, overshoot only happens once accumulation
   has already reached `>= threshold + 1 > threshold`, so capped and uncapped
   agree on the test for every integer height, and the chosen
   topline/`cursor_lnum` (hence `bottom_padding`, `scrolloff`, fold-snap) are
   untouched. `max_height` is 0.12+ (0.11 rejects unknown opt keys with
   `"invalid key"`). There is no 0.11 fallback path — this deliberately raises
   the plugin's floor to 0.12 (a stable release, not nightly), dropping 0.11
   support in exchange for a single code path: `health.lua:15`
   (`required_version`), `README.md:53`, `CLAUDE.md:6`.

2. **Short-circuit the steady states before any measurement** (the current
   `target == old_topline` early-return sits *after* the expensive search).
   Three guards, in order — each also establishes an invariant the survivors
   rely on:
   - `max_topline and max_topline <= old_topline` → return. Pinned steady
     state — every streamed chunk while a prose pin holds — for O(1): the
     clamp `max(old_topline, min(max_topline, natural_target))` can only
     yield `old_topline`.
   - `old_topline >= last_line` → return. The tail line is already at or above
     the top of the viewport, so `natural_target <= last_line <= old_topline`
     and no forward scroll is possible (scroll_down never scrolls up). Placing
     it here makes `old_topline < last_line` hold for everything below, which
     is what keeps the next two steps in bounds. This guard is what closes the
     tall-last-line gap: when the single last line is taller than
     `effective_winheight`, the height guard below would *not* fire
     (`natural_target = last_line`) even though `natural_target <= old_topline`,
     and the search would compute a start of `old_topline + 1 > last_line` — an
     out-of-range `natural_target`. (A buffer that *shrinks* below its topline
     does not reach this guard — vim clamps the reported topline back into
     range before `scroll_down` reads it, so the height guard below handles
     that case.)
   - `height_to_last(old_topline) <= effective_winheight` → return. The tail
     already fits, so `natural_target <= old_topline`. One capped call, and
     `start_row = old_topline - 1 <= last_line - 1` holds by the previous
     guard, so no "Line index out of bounds" (no `ot`/`last_line` clamp
     needed).
   - Past all three, `natural_target > old_topline` is guaranteed (the height
     guard did not fire), so start the binary search at `lo = old_topline + 1`
     (bounded by `hi = last_line`; valid since `old_topline < last_line`), and
     drop the now-dead full-buffer `height_to_last(1)` check, the
     `max(old_topline, …)` clamp, and its early-return.

Steady-state cost per streamed update becomes one capped height call (≈ the
conceal cost of one redraw) when following the bottom, zero while pinned;
transition scrolls cost O(winheight · log buffer).

Alternatives considered and dropped: native bottom-align (cursor to
`last_line` + `normal! zb`) computes the same topline in C but changes edge
semantics — `bottom_padding` would degrade to buffer-line granularity via
`<C-e>`, `scrolloff` fights the transient cursor placement in the
`max_topline`-capped case, and `L` is a jump motion; manual range-capping /
galloping from the tail reimplements what `max_height` does natively.

## Verification

- `make validate` — `message_writer.test.lua:699-797` has four `scroll_down`
  cases (max_topline cap, never-scroll-up, rendered-screen-line behaviour)
  pinning the preserved semantics. They assert final topline/cursor, not call
  counts, so they stay green without edits — but none sets `conceallevel=2` (so
  they do not exercise the perf win) and none reaches the
  `old_topline >= last_line` guard from Fix step 2. A buffer *shrink* below
  the topline does not reach it — vim auto-corrects `topline` back into range
  before `scroll_down` reads it (so guard 3 handles it). The guard is reached
  when the topline legitimately sits on the last line and that line is taller
  than the window: the tail-fits check cannot short-circuit, and without the
  guard the search starts below `last_line` and computes an out-of-range
  target. The added case ("no-ops without error when topline sits on the last
  line") pins exactly this.
- Re-run the `sample` recipe above while streaming into a long chat: the
  `nvim_win_text_height → decor_conceal_line → ts_query_cursor` chain must be
  gone from the main thread (idle in `uv__io_poll` between renders).
