# Plan — per-prompt token usage to the UI

Goal: show the token cost of each completed prompt turn as a quiet, glanceable
footer in the chat. The signal that matters is *spotting a turn that burned a
lot* — so display is strictly **per-turn**, not cumulative. v1 stores nothing:
render at turn end, keep no state.

## What data actually exists (and what doesn't)

| Granularity | Source | Status |
| --- | --- | --- |
| **Per prompt / turn** | `session/prompt` response `usage = {inputTokens, outputTokens, totalTokens}` | Arrives every turn; currently only read on unexpected `stopReason` (`session_recovery.lua:43`, `surface_unexpected_response`). This plan renders it. |
| **Whole-context snapshot** | `usage_update` notification `{used, size, cost}` | Already captured as `self._usage` (`session_manager.lua:421`); drives `/context`, the header `Nk`, and the session `cost`. Not touched by this plan. |
| **Per block / per tool call** | — | **Does not exist.** ACP emits no token attribution on tool calls or chunks; the bridge forwards none. Byte-counting rendered content is not tokenization. Do not chase it. |

### Why per-turn, not cumulative

A cumulative token sum would conflate two scales on one line and wouldn't serve
the goal: a counter that only climbs hides the spike you're hunting for — the
per-turn number *is* the waste detector. Cumulative views already exist from
canonical sources: context fill is the header `Nk` (`self._usage.used`), and
session cost is `self._usage.cost`. A session grand-total belongs to a future
`/usage` panel, not the ambient footer.

### Zero-usage turns emit zeros

`usage` is all-zeros on stalls, cancels, and silent upstream auth failures (see
provider-system skill). A **cancelled** turn reaches the *success* branch —
`surface_unexpected_response` returns early on `stopReason == "cancelled"`, so no
error is raised — meaning the render path *is* hit on cancels. The renderer must
no-op on zero usage rather than print a misleading "0".

## Implementation

No retained state. The capture site already holds the one `usage` value the
footer needs, so v1 reads it and renders immediately.

1. **Rename `append_separator` → `finalize_turn`** (`message_writer.lua:447`,
   8 call sites in `session_manager.lua` + test references). The name is a
   contract and the current one lies: the function resets all per-turn state and
   reflows streamed prose, then *ends* by appending the trailing blank `""` line.
   Body unchanged — rename only.

2. **New `MessageWriter:set_turn_usage(usage)`.** Stamps a right-aligned
   `virt_text` extmark on the trailing blank line, in a dedicated namespace
   `NS_TURN_USAGE = nvim_create_namespace("agentic_turn_usage")`. No-op on
   zero/missing usage:

   ```lua
   function MessageWriter:set_turn_usage(usage)
       if type(usage) ~= "table" then return end
       local input = usage.inputTokens or 0
       local output = usage.outputTokens or 0
       if input == 0 and output == 0 then return end   -- stalls/cancels/auth-fail
       -- last line = the blank "" finalize_turn just appended;
       -- format both with %.1fk → "1.2k in · 0.4k out";
       -- set_extmark virt_text_pos = "right_align", hl = Theme TURN_USAGE
   end
   ```

3. **Call site.** In the `send_prompt` success branch
   (`session_manager.lua:1551`), capture `response.usage` into a local. After
   `finalize_turn()` appends the blank line (`:1555`), call
   `set_turn_usage(usage)` — the anchor line must exist first.

4. **Highlight.** Dedicated group `TURN_USAGE = "AgenticTurnUsage"` in
   `theme.lua`, `{ link = "Comment" }` (default). One-role-one-group matches the
   existing granularity (cf. the three separate `GREP_*` groups). Update
   `README.md` per the theme-group convention.

## Display

Right-aligned `virt_text` on the trailing turn-boundary blank line, dim
(`AgenticTurnUsage` → Comment), e.g. `1.2k in · 0.4k out` at the far right.

- **Input and output only**, `%.1fk` rounding — sub-rounding turns are noise.
  No total (it's just the sum; the header already shows cumulative context).
- No new buffer line — reuses the blank line `finalize_turn` writes, so it isn't
  yanked/copied and doesn't shift fold math. The blank line is plain markdown,
  never inside a `fold$` fence, so it is never folded — the footer stays visible.
- **Stamp once, never update or clear.** A completed turn's cost is final. The
  next turn appends *after* the blank line, so the extmark rides along unshifted.

## Out of scope (v1)

- **Retention / persistence.** Nothing is stored, so footers vanish on
  `session/load` — reloaded turns show no usage line. Accepted for v1.
- **`/usage` panel.** The obvious next addition. It and persistence arrive
  together as one feature, with a real consumer to validate the retained shape.
- Per-block / per-tool-call attribution (not in protocol).
- Client-side token estimation; cost modelling beyond the provider's `cost`.
