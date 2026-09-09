# Bracket every prose run, live

Status: **shipped** — the code is the reference; what remains here is the
measurement behind the gate and the two gaps § "Out of scope" records. Unit 7 of
[`PLAN-gutter-identity.md`](PLAN-gutter-identity.md),
revising unit 3. Today one prose run per turn gets a `╭─ │ ╰─` region, drawn once
the turn ends. Every run should get one, drawn as it streams, gated on the run
holding more than a single paragraph.

Line numbers are deliberately absent: `message_writer.lua` moves under this work.
Anchors are function names.

## What a prose run is

The rows a writer streams between two non-prose writes. Nothing else defines it —
`_reflow_chunks(bufnr, true)` is called at exactly the points where one ends, and
a run therefore cannot span a tool call by construction:

| `message_writer.lua` | ends the run because |
| --- | --- |
| `_write_collapsed_region` | a thought run or a hook block follows |
| `write_user_prompt` | the user interrupted |
| `write_notice` | a command notice follows |
| `write_error_message` | an error follows |
| `finalize_turn` | the turn ended |
| `emit_divider` | a subagent's Task closed |
| `write_tool_call_block` | a tool call follows |

`reset_turn_state` is an eighth site that drops `_prose_run_start_line` without
reflowing. Anything else tracking a run has to be released there too — see
"Releasing the ids".

## The rule this revises

Unit 3 gave the closing summary a region because it is "the only one whose end is
known: every other run ends at the next tool call, an unknown future point."

That does not hold. The bracket is never drawn while the end is unknown — it is
drawn at the flush, retroactively, by which time buffer end *is* run end. The
closing summary is not the only run with a knowable extent; it is the only run
whose start is read before `_reflow_chunks` discards it.

The rationale's second half — a rail on nearly every row marks nothing out —
still describes the outcome accurately (runs and tool blocks alternate, both
railed, so the gutter ends up occupied almost everywhere). It is accepted: the
grouping is what the gutter is for.

## The region opens on the run's first row of text

The empty `###` a run emits after an interrupting block belongs to **neither**
region. It has no content, and it exists for the block above it — `write_message_chunk`
emits it so treesitter-context stops pinning the tool call's filename. The section
it opens is an artifact of ATX headings closing the previous section by starting a
new one, not something the reader is looking at. So it carries no sign, and
`render_prose_region` opens on `first_prose_row`. **Delete `section_break_row`**
rather than leaving it uncalled — `render_prose_region` is its only caller, and
selene's `unused_variable = "deny"` fails `make validate` on a dead local without
a `_` prefix.

This reverts the behaviour of `057d7ca`, which read the same row as the section
the prose *opens*. Two mechanical reasons beyond the structural one, either of
which is sufficient:

- **The viewport pin and the opener become the same row.** `_prose_anchor_line` is
  set from `first_prose_row` and `_scroll_now` clamps `max_topline` to it, so a
  `╭─` one row above — on the `###` — is scrolled out of view for the whole of
  the streaming this plan makes live. The reader would watch `│ │ ╰─` grow with
  no corner.
- **A fold anchored on the `###` would summarise an empty row.** If unit 8 folds
  these regions, the fold's first row is the one foldtext replaces — the same
  property that makes `folds.scm` fold `code_fence_content` rather than
  `fenced_code_block`.

Nothing motivated `057d7ca` beyond its stated rationale: `context.scm` already
excludes the empty `###` (both captures guard on `(atx_heading (inline))`),
`[[`/`]]` stops only on `NS_USER_ACTIONS` so a decoration corner is invisible to
navigation, and the row carries no `conceal_lines`.

With one anchor, `render_prose_region` needs one rejection rather than two: the
old `end_row <= header_row` check becomes dead, since a blank row strictly inside
the run implies at least three rows, and `last_drawn_row`'s past-the-end return
leaves the gate's scan range empty, which rejects anyway.

**The opener is not guarded against a concealed fence delimiter** the way
`last_drawn_row` guards the closer, so a run whose first drawn row is a fence gets
an invisible `╭─`. Pre-existing for runs with no `###`; `057d7ca` incidentally
covered the rest and this re-widens it. 12 of 12,416 signed runs in the cache
(0.1%) — recorded so the asymmetry does not read as an oversight.

## The gate: a blank row between the run's first and last prose rows

A run brackets only when it holds a blank row — that is, more than one paragraph.
Single-line asides between tool calls ("Now let me check X.") stay unsigned.

**Measured from the first row of text, never from the `###`.** That boundary is
always followed by a blank row, so a gate anchored on it passes *every* run that
resumes after a tool call and excludes nothing. That is not a corner case: over
39,680 agent prose runs in 1,967 cached sessions, `###`-opened *and*
single-paragraph is the largest single category at 39.6%, and 88% of those are
followed straight by another tool call — they are exactly the one-line narrations
the gate exists to reject.

| opens with `###` | multi-paragraph | share |
| --- | --- | --- |
| yes | no | 39.6% |
| no | no | 29.1% |
| yes | yes | 16.0% |
| no | yes | 15.3% |

So a blank-row gate signs 31.3% of runs. Bracketing every `###`-opened run instead
would sign 55.6% — including all 15,726 one-liners — while still missing the 15.3%
that are substantial prose right after a prompt, which carry no `###` at all.

The measured property is **a blank line interior to the stripped text**, not
`"\n\n"` anywhere in it: `first_prose_row` and `last_drawn_row` both strip leading
and trailing breaks before the gate sees them. Counting naively instead gives
32.7%, so a re-derivation that skips the strip will not reproduce the table.

Two population caveats. Notices and errors are display-only and never persisted,
so a buffer run one of them ends is not split in the history — a slight
under-count of runs and over-count of multi-paragraph. And subagent content is not
persisted at all, so these figures say nothing about the subagents pane.

`last_drawn_row` fetches the run's lines but does not return them; the gate needs
its own `nvim_buf_get_lines`. Name the predicate as a local beside
`first_prose_row` — `has_paragraph_break(bufnr, from_row, to_row)` — rather than
inlining the scan.

**Not a row-count threshold**, which measures the viewport rather than the text.
`_get_wrap_width()` returns the chat window's width, and **0 when that window has
`wrap` set** — under soft wrap `wrap_prose` returns its input unchanged, so a
paragraph of any length is one buffer row. The same reply would bracket under
`nowrap`, not bracket under `wrap`, and change verdict when the split is resized.
A blank row is a property of what the agent wrote and reads the same under both.
(`wrap` is user-reachable: `Config.windows.chat.win_opts` merges over the
`wrap = false` default.)

Two behaviour changes this accepts:

- **A multi-row single paragraph no longer brackets.** That is the point of
  preferring content over viewport, but it is a loss relative to today, and four
  cases in the existing `closing summary region` test block encode the old rule.
- **A run that is only a fenced code block loses its bracket** — no blank row
  between the opener and the code. Today it brackets, but on a concealed
  fence-delimiter row, so the `╭─` was never visible anyway.

## Live rendering

Signs do not survive `nvim_buf_set_lines`, which is what the streaming reflow in
`_reflow_chunks` does to the run's rows. Measured on a clean nvim, signs `0`–`4`
on rows 0–4:

```
replace row 2 with 1 line     -> 0:0  1:1  3:2  3:3  4:4    displaced
replace rows 1-4 with 4 lines -> 0:0  5:1  5:2  5:3  5:4    collapsed onto one row
```

This is not an obstacle, because a tool call block already resizes without losing
its rail — by rebuilding it, not by surviving. `update_tool_call_block` clears its
decorations by tracked id (`Renderer.clear_decoration_extmarks`), replaces the
lines, and re-renders (`Renderer.render_decorations`). Prose takes the same shape.

`_prose_run_start_line` needs no help: it is already carried across a block
growing earlier in the buffer by `shift_across_block`.

### Cadence: per row grown, not per paragraph

A reflow is not the only thing that moves the rail. `_reflow_chunks(flush_all =
false)` returns "no complete paragraph yet" until a blank row lands, but the run
gains rows on every chunk carrying a newline. Stamping only at reflow strands
`╰─` mid-region with unrailed rows beneath it — verified: a region stamped over
rows 0-2, then grown by two rows, keeps `╰─` on row 2 and leaves rows 3-4 bare.

So the re-stamp fires whenever the run's last drawn row moves, which is per
chunk-that-grew-a-row. A full clear-and-re-render at that rate is O(N²) over a
run; rewrite the old `╰─` to `│` in place through `Renderer.restamp_border` — the
reusable wrapper over `ExtmarkBlock.set_sign`, already hardcoding the rail's
`CODE_BLOCK_FENCE` group — and stamp `╰─` on the new last row.
Clear-and-re-render is then only needed when a reflow rewrote rows. The
incremental path has to keep `render_block`'s documented "ids come back
front-indexed by buffer offset" invariant, appending one id per row grown.

### Releasing the ids

`render_block` returns the ids; they have to be tracked to be cleared, and
**released in the same statement that releases `_prose_run_start_line`** — at
every run end and in `reset_turn_state`. Otherwise the next run's first re-stamp
clears the *previous* run's ids and deletes a committed bracket. That failure is
invisible in a single-run test and reproduces today's one-bracket-per-turn
behaviour while looking implemented.

The tracker lives on the `MessageWriter` instance, not at module level
(`.claude/rules/multi-tabpage.md`). `MessageWriter.clear_regions` wipes
`NS_DECORATIONS` wholesale and leaves the ids dangling; deleting a dead id is a
`pcall` no-op, so no extra teardown is needed.

Nothing here obliges a new `_auto_scroll` call: sign extmarks change no line
counts and add no `virt_lines`, and all seven flush sites already run inside
`_with_modifiable_suppressed`.

## Structure: one named method, not a fourth job for `_reflow_chunks`

`_reflow_chunks` already carries three jobs its name does not (reflow, close an
unclosed fence, drop the run start). Rather than adding a fourth and then
juggling its two early returns, give the seven callers a method that says what
they want:

```
MessageWriter:_end_prose_run(bufnr)  -- reflow to the end, bracket the run, drop the start
```

All seven invoke `_reflow_chunks(bufnr, true)` as the first statement of their
`_with_modifiable_suppressed` closure, so this is a straight substitution.
`_reflow_chunks(bufnr, true)` is then called from one place, the render lands
naturally after the fence append, and the "no run end can miss the drop" property
holds by construction rather than by discipline.

Its `flush_all` branch has two early returns, but only one could ever need a
render of its own. `if not start then return end` is unreachable with a live run:
`_prose_run_start_line` is set only in the same statement as `_chunk_start_line`
and cleared only alongside it, so a non-nil run start implies a non-nil start.
Only `start >= buf_end` leaves rows worth bracketing. `_end_prose_run` makes the
question moot, which is the argument for the restructure over threading the
render through the branch.

## The subagent pane

This fixes it. A prose run in the subagents buffer ends at `emit_divider`, fired
per-Task from `SessionManager:_mark_task_closed`, or at `write_tool_call_block`
for the subagent's own calls. Either way the flush drops the run start, and
`subagent_writer:finalize_turn()` does not run until the turn ends, by which
point there is nothing left to bracket — so the pane has never drawn one.
Reproduced: prose → `finalize_turn` yields the full rail; prose → `emit_divider`
→ `finalize_turn` yields no signs at all.

`emit_divider`'s no-op guard precedes its flush, so a run whose last chunk
carried no newline (no line-count change) reaches `finalize_turn` with its start
intact. Under the blank-row gate such a run never brackets anyway.

Not a deliberate exclusion. Commit `8f01a8b` touched only `message_writer.lua`,
its test and the notes, and records the gaps it accepted; the subagents buffer is
not among them. The `subagent_writer:finalize_turn()` call is commented as a
per-turn state reset and silently inherited a rendering job it could not do.

A Task close is a *better* end signal than the main branch's, not a worse one.

## Out of scope

`write_message` — the whole-message path — never sets `_prose_run_start_line`, so
session restore and injected agent messages get no bracket. That is the gap
`PLAN-gutter-identity.md` § 3 already records.

It is not only a replay concern: `SessionManager:_on_stdout_text` calls
`write_message` *while generating*, appending rows with no flush. A live run's
start survives, and the render — which scans to buffer end — brackets across the
injected text. Pre-existing (`finalize_turn` has the same exposure today), but
this work makes it fire per run rather than once per turn.

Folding these regions is unit 8, not part of this work.

## Prose the change invalidates

The superseded rule is asserted in six places besides the code:

- `_prose_run_start_line`'s `@field` — "Read by `finalize_turn` to bracket the
  turn's closing summary"
- `finalize_turn`'s docstring — the paragraph giving unit 3's rationale
- `_reflow_chunks`'s docstring — "drops the run start a closing summary would
  have been bracketed from. A caller that wants that row has to read it before it
  flushes"
- `.claude/skills/rendering/SKILL.md` § "Tool call block layout" — "the run that
  closes a turn opens on a plain `╭─` … called from `finalize_turn`"
- `doc/agentic.txt` — "the prose closing a turn"
- `PLAN-gutter-identity.md` § Closed 3 — needs the gate added to its
  superseded-scope note

Plus `extmark_block.lua`'s module header, which opens with "Signs survive
`nvim_buf_set_lines` line-replacement without delete/recreate cycles, so updates
to a tool call block do not displace its decorations." The measurement above
contradicts the premise. The conclusion still holds for the one path it describes
— the `already_has_diff` branch of `update_tool_call_block` refreshes only the
status footer via `nvim_buf_set_text` and runs no `set_lines`. Rewrite it to say
that: signs are re-stamped after a line replacement, and stay put only where the
block is updated in place.

## Interaction to re-check

[`PLAN-hooks_in_chat.md`](PLAN-hooks_in_chat.md) § "Triggers" 2 drains hook
records after the writer for two reasons, and only one weakens.
`SessionManager:_finalize_turn`'s docstring gives them: a region written first
would end the prose run and leave the summary unbracketed — which stops being a
loss once every run brackets — *and* the turn-usage footer is stamped on the
buffer's last row, which a drained region would move out from under it. The
second still forces drain-last. Update that note without implying the whole
constraint dissolved.

## Phasing

1. Render at every run end, gated on a paragraph break, via `_end_prose_run`.
   Covers all seven ends including the subagent divider, and deletes the
   read-before-flush in `finalize_turn`.
2. Track and release the region ids; re-stamp on row growth for the live rail.

Tests are co-located `message_writer.test.lua` per `.claude/rules/tests.md`. The
existing `closing summary region` block needs **rewriting, not extending**: four
of its cases use single-paragraph bodies and change verdict under the gate, and
`gives a turn that ends in a tool call no region` keeps passing for a new reason
(the run now reaches the render and is rejected there), so its name stops
describing what it tests.

Two of those four — `opens on the section boundary after a tool call` and
`follows the run start across a tool block resize` — assert the opener row holds
`"###"`, so they break on the relocation alone, gate or no gate. `057d7ca`
renamed the first of them from `opens on the first prose row after a tool call`;
restoring that name is the clearest signal in the diff that this half is a revert.

`make validate` is the gate.
