# Feature: collapse thinking to one fold row

Unit 5 of 5. Overview and order: [`PLAN-gutter-identity.md`](PLAN-gutter-identity.md).
Depends on unit 1 for `glyphs.lua`, the section-break method and the writer
discipline `write_notice` documents; on unit 2 for the gutter placement rule and
the bracket-namespace decision. Unit 3 shipped ahead of it on a stopgap this one
retires (see "Cleanup this unlocks").

Supersedes TODO.md's "Grey out agentic inner thinking".

## Current state

Thinking is displayed, just not marked as such. `agent_thought_chunk` arrives at
`session_manager.lua:530`, is stored in history as `type = "thought"` (`:541`),
replayed on restore (`session_restore.lua:339`), and rendered by
`MessageWriter:write_message_chunk` — the same method as ordinary prose. Its only
special handling is a `\n\n` separator on the thought→message transition
(`message_writer.lua:916`). No highlight, no marker, no fold. So a reader cannot
tell thinking from output, which is why it reads as "not displayed": it is
indistinguishable from the answer.

## Goal

One row per thought run:

```
󰧑  ··· 37 lines · 1.2k chars ···
```

That row **is** the closed fold. The thought text goes into a `markdown-fold`
fence closed at render, the marker glyph is a `sign_text` extmark on the fence's
first body row, and the fence delimiters are `conceal_lines`-concealed to zero
height — so the whole run occupies exactly one screen row, and `zo` reads it.

No `###` heading. That is the design decision worth stating, because the sibling
notes all use headings:

- A heading would cost 2–3 rows (heading + fold row + blank), not one.
- A heading whose section contains a fence **matches `context.scm`'s first
  capture**, and with `max_lines = 1` + `trim_scope = 'outer'` the innermost match
  wins — so a `### thought` marker would pin the breadcrumb for the rest of the
  turn, exactly the hazard unit 1's fence-less notices avoid. (Verified by spike;
  a boundary `###` would shrink it back, but that is machinery bought to fix a
  problem the headingless form does not have.)
- No heading means no `[[`/`]]` question either: thought runs are far more
  frequent than notices, so making them navigation stops would drown the notices
  unit 1 put there deliberately. The marker sign goes in the decoration
  namespace.

Without a heading the fence simply sits inside the enclosing `## prompt` section,
which is where prose fences already sit today — the prompt keeps pinning.

Glyph options: 󰧑 brain, 󱍄 head_lightbulb, 󰔟 timer_sand. 󱍐 head_sync is taken by
the model-switch notice and 󱌼 head_cog was its alternative, so 󰧑 keeps the
head-family distinction clean.

## The summary figure

`folds.lua`'s foldtext already prints `··· N lines ···`, so the marker needs
nothing to be informative — but lines are a weak proxy for how much thinking
happened, and a character count is the only other figure available (nothing
upstream reports thinking tokens). Extend the foldtext for thought folds to
`··· N lines · <count> chars ···`.

Two things the count must get right:

- **Characters, not bytes.** `#text` counts bytes and thought text is full of
  `—`, `·`, box-drawing and pasted CJK. Use `vim.fn.strchars`.
- **Sub-1k runs are the common case.** `%.1fk` renders a 400-char run as `0.4k`.
  Needs a plain-integer branch below 1000.

There is no existing helper: `session_manager.lua:661-662` and
`message_writer.lua:779` both hand-roll `string.format("%.1fk", n/1000)`, and
unit 1 edits the first pair. That is three sites — add one formatter (in
`utils/text_wrap.lua`, next to `truncate_to_width`) rather than a fourth
hand-roll.

## Buffer the run, render once

A run's length is only known when it ends, so the fence and its count are written
at run end. Nothing shows while the agent thinks except the status indicator,
which already says "thinking".

The alternative — append body chunks inside the fence as they arrive and stamp
only the count at the end — gives live feedback and would avoid buffering, but it
needs the fence open across an unknown number of chunks while `_reflow_chunks`
rewrites the same range — `set_lines` over a row is what collapses the signs on
it. Not worth it for content that is closed by default.

### Every flush site

Name the flush as one method (`_flush_thought_run`) and call it from **all** of
them. The set is `_reflow_chunks(bufnr, true)`'s callers — its docstring at
`message_writer.lua:779-786` lists them — plus unit 1's writer:

| Site | Why |
| --- | --- |
| `finalize_turn` | normal turn end, and `<C-c>` (the prompt callback runs on `stopReason = "cancelled"`) |
| `write_tool_call_block` | thinking interrupted by a tool call |
| `write_user_prompt` | mid-turn submit, and replay ordering — the `:393` comment documents `thought → prompt → thought` |
| `write_error_message` | turn ended by an error |
| `emit_divider` | subagent Task close |
| `write_notice` (unit 1) | mid-turn command notice |
| end of `SessionRestore.replay_messages` | see below |

A thought→message transition is *not* a separate site: once thoughts leave the
prose path, the next message chunk flushes through the same method.

**Buffer loss is display-only, by decision.** A provider that never answers
`session/cancel`, a `/new` (`_cancel_session`), or a widget close drops an
unflushed buffer. The text is in `chat_history` on the main branch, so nothing is
destroyed there — but see the subagent exception below.

## Subagent runs

Thought chunks route to `subagent_writer` for tagged updates
(`session_manager.lua:533`), and `_mark_task_closed` calls
`subagent_writer:emit_divider()` per Task (`:493`). Without a flush at the
divider, a run buffered when Task A closes appears under Task B — hence its row
in the table above.

Subagent thoughts are **not** persisted: only the main branch adds to
`chat_history` (`:539-545`). So on that branch a dropped buffer is real data loss,
not a display gap. Either flush defensively (the divider row covers the common
case) or accept it knowingly.

## Reusing the sidecar body machinery

Three of the four ingredients work from a non-tool-call path as-is: the
`markdown-fold` info string, `Renderer.set_dim_range` (already called from
`message_writer.lua:1398`) and `self:_close_fold(anchor)`.

The fourth does not: **`safe_fence` is file-local** (`tool_call_renderer.lua:146`)
and must be exported. It is load-bearing here — models routinely write
triple-backtick code inside thinking, and a body fence of exactly three backticks
closes early, which is `bug-unclosed-prose-fence-runaway-fold.md`'s failure mode.

`prepare_block_lines` is **not** reusable (takes a `ToolCallBlock`, dispatches on
`kind`); this path builds its own two-fence-plus-body lines and passes its own
`fold_anchor`.

Two consequences of the fold path itself:

- **A single-line run cannot fold.** `folds.lua:76` drops one-line matches
  (`if last > first`), mirroring `use_fold = #wrapped > 1` for sidecars. Below
  that threshold, emit the marker with no body rather than an unfolded fence
  showing raw thinking.
- **The fold close silently fails in insert mode**, which is the dominant case
  here — the agent thinks while the user types the next prompt.
  `flush_pending_fold_ops` (`message_writer.lua:1289`) swallows `E490: No fold
  found` and drops the op with no retry; its own comment names insert mode as the
  live cause. For a tool body that is cosmetic; for thinking it defeats the
  feature. Fix the root cause — re-arm on `InsertLeave`, keeping the anchor — and
  note that this repairs existing sidecar bodies too (filed in TODO § Bugs).
- **`wrap_prose` the body** as sidecar bodies are, so the foldtext's line count
  matches what `zo` shows.

## Cleanup this unlocks

`_last_message_type` exists for the `\n\n` thought→message separator and for the
stopgap unit 3 shipped on: `finalize_turn` skips the closing-summary bracket when
a turn ends on a thought chunk, because a thought run is a prose run today.
Delete the field and that gate together — once thinking is its own region, a turn
ending on one has no trailing prose run to bracket and the gate has nothing left
to decide.

`_prose_run_start_line` needs no entry in a clear list: it is dropped inside
`_reflow_chunks(bufnr, true)`, so `_flush_thought_run` ends the prose run before
it by following the discipline below. A turn of *prose → thinking → finalize*
then brackets nothing, rather than bracketing from the prose start into the
thought block.

## Replay

`SessionRestore.replay_messages` (`session_restore.lua:332-360`) is a bare loop
and neither caller (`session_manager.lua:2666`, `:2679`) calls `finalize_turn` —
so a history whose last entry is a `thought` leaves the run buffered until the
next turn's first write, rendering the previous session's thinking after the new
prompt heading. Flush at the end of the loop.

The restore *picker* preview (`session_restore.lua:223`) renders thoughts as
plain text and is a separate surface — leave it.

## Implementation surface

- `lua/agentic/ui/message_writer.lua` — route `agent_thought_chunk` into a run
  buffer; `_flush_thought_run` (marker sign + dimmed folded body, following the
  same discipline `write_notice` documents: `_reflow_chunks(bufnr, true)` first,
  `_auto_scroll` before the write, `_with_modifiable_suppressed`,
  `_release_prose_pin`, `sign_text = glyph .. " "`, `right_gravity = false`, row
  computed after the append); calls at every site in the table; delete
  `_last_message_type`.
- `lua/agentic/ui/tool_call_renderer.lua` — export `safe_fence`.
- `lua/agentic/ui/folds.lua` — thought-fold foldtext with the character count.
- `lua/agentic/utils/text_wrap.lua` — the shared `k`-suffix formatter.
- `lua/agentic/glyphs.lua` — the thinking glyph (unit 1 creates this module).
- `lua/agentic/session_restore.lua` — flush at the end of `replay_messages`.
- `queries/agentic/folds.scm` / `injections.scm` — no change; they match the
  `fold$` suffix generically.

The body's `set_dim_range` extmark lands in `NS_DECORATIONS`, which nothing
clears — the same gap unit 2 flags for the prompt bracket. One fix covers both.

## Tests

- A thought run followed by a message chunk renders one closed fold with the
  marker sign on it, its count from `strchars`, and no thought prose visible.
- A sub-1000-char run renders an integer count, not `0.4k`.
- A single-line run renders the marker with no fence.
- A run containing a triple-backtick block still folds as one block (`safe_fence`).
- Two thought runs separated by a tool call produce two markers.
- Each flush site in the table flushes.
- Replay through `session_restore` produces the same marker as the live path,
  including when the last stored message is a thought.
- A subagent run buffered across a Task close renders under its own Task.
