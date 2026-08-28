# Feature: bracket the turn's closing summary

Unit 3 of 5. Overview and order: [`PLAN-gutter-identity.md`](PLAN-gutter-identity.md).
Builds on the shipped region-sign API: `ExtmarkBlock.render_block` takes
`header_sign`, and rails live in `Renderer.NS_DECORATIONS`.

## Goal

Group the prose the agent writes to close a turn into one region — `╭─ │ ╰─` in
the sign column — so a turn's conclusion reads as a block rather than trailing
off into unmarked lines.

## Why only the closing summary

Agent prose otherwise keeps its bare gutter. Prose is most of the buffer, so
railing all of it would leave the sign column occupied nearly everywhere, at
which point the rail marks nothing out and only the opening row still carries
meaning.

The closing summary is also the cheap case. Every other prose run ends at an
unknown future point — the next tool call — but the closing summary ends at
`finalize_turn`, which is already a hook.

Its opener is `SIGNS.HEADER` (`╭─`), not an identity glyph: prose is the one
region with nothing to announce, which is why unit 2 keeps that constant.

## The run start needs a new field

`_chunk_start_line` does **not** hold it. `_reflow_chunks` advances it on every
non-flushing call (`message_writer.lua:866`), so by `finalize_turn` it points at
the last un-reflowed paragraph, not the run start — spiked against the real
writer: three streamed paragraphs from row 0 left `_chunk_start_line = 4`.

`_prose_anchor_line` *is* the run start, but it is unusable here: `finalize_turn`
releases the pin at `:668` before the reflow at `:671`, and it is never set at all
when `_auto_scroll_paused` is true (`:1004`) or when leading blanks exceed the
4-line forward scan (`:1006`).

So add `_prose_run_start_line`: set where `_chunk_start_line` transitions from
nil, and captured in `finalize_turn` **before** the reflow. Reset it with the
other per-turn flags.

Clear it wherever a prose run ends — which is every `_reflow_chunks(bufnr, true)`
caller, listed in that method's docstring (`message_writer.lua:779-786`): turn
boundary, tool call, prompt, error and `emit_divider`. Plus unit 1's
`write_notice` and unit 5's thought flush. Enumerate them rather than describing
them, or the divider gets missed.

## Rendering

`message_writer` calls `ExtmarkBlock.render_block` directly with
`header_sign = ExtmarkBlock.SIGNS.HEADER` — not through
`Renderer.render_decorations`, whose name and job are tool-call blocks. Use
`Renderer.NS_DECORATIONS` (not `MessageWriter.NS_USER_ACTIONS`, whose marks
`[[`/`]]` all read) and the same `hl_group` the tool-block rail uses. Note
`render_region_rail` in `message_writer` already does exactly this for prompts
and notices — a prose region differs only in taking `╭─` for its opener.

## Boundaries

- **The turn-usage footer is not in the way.** It is a right-aligned `virt_text`
  extmark on the trailing blank line `finalize_turn` appends
  (`message_writer.lua:764-784`), not buffer content, so it cannot collide with a
  sign. The only requirement is that `╰─` lands on `line_count - 2`, the last
  prose row, not `line_count - 1`.
- **Both writers.** `finalize_turn` also runs on `self.subagent_writer`
  (`session_manager.lua:1943`), and the subagents split shares
  `signcolumn=yes:1` (`widget_layout.lua:203`). The mechanism lives on
  `MessageWriter` and `_prose_run_start_line` is per-instance, so the subagent
  bracket comes for free. It materialises rarely, though: `_mark_task_closed`
  → `emit_divider` (`:493`) flushes after each Task, which clears the run start —
  so a subagent gets a bracket only for prose written after its last Task closed.
- **A turn ending in a tool call gets no group** — there is no trailing prose run.
- **A turn ending in a thought run** is not a case to decide here.
  `agent_thought_chunk` currently flows through the same prose path, but
  `feature-thinking-summary-line.md` collapses thought runs to a single marker
  line, after which a thought run is not a prose run at all. Implement that unit
  first, or gate on `_last_message_type` in the meantime.
- **Fenced code inside the closing prose** gets `│` on every fence row, including
  the delimiter rows — which are `conceal_lines`-concealed to zero height at
  `conceallevel=2`, so those signs simply do not show (the same behaviour the
  `ordinal` docstring records for tool blocks).

## Implementation surface

- `lua/agentic/ui/message_writer.lua` — `_prose_run_start_line`; the
  `render_block` call in `finalize_turn`, before the trailing blank is appended or
  accounting for it; per-turn reset alongside the other flags.

## Tests

- A streamed prose run followed by `finalize_turn` carries `╭─` on its first row,
  `│` between, `╰─` on the last prose row — with the trailing blank (and its
  usage footer) outside the bracket.
- Multiple paragraphs with reflows in between still bracket from the run's first
  row, not the last paragraph's.
- A turn ending with a tool call gets no group.
- The subagents buffer brackets prose written after its last Task divider, and
  nothing before it.
