# Plan: one shift rule for prose-run rows, one end-of-run reflow
Status: spec

## Relevant files
- `lua/agentic/ui/message_writer.lua` — fields `_chunk_start_line`,
  `_prose_run_start_line`, `_prose_anchor_line` (class docstring);
  `_shift_prose_rows_below`, `shift_across_block`, the inline pin shift in
  `_rerender_tool_call_block`, `_insert_after`, `_clear_prose_pin`;
  `_reflow_chunks`, `_end_prose_run`, `write_message_chunk`,
  `_rebuild_prose_region`, `mark_table_row_ends`
- `lua/agentic/ui/message_writer.test.lua` — "holds the prose pin on the
  content it was set on", "follows the run start across a tool block
  resize", "keeps the marker on the heading across a chunk reflow",
  "brackets a streamed run down to its last prose row", "opens on the run's
  first row, not the last reflow's", `describe("prose anchor pin")`
- `tests/integration/auto_continue_chunk_flush.test.lua` — asserts
  `_chunk_start_line` is nil after the flush
- `.claude/skills/session-lifecycle/SKILL.md` — cross-turn table, row
  `_chunk_start_line`
- Skills: `rendering`, `follow`, `session-lifecycle`, `neovim`
  (`references/rendering.md` § extmarks under `set_lines`)
- Notes touching the same functions: `notes/bug-streamed-code-lines-get-hard-wrapped.md`
  (the streaming fence clamp), `notes/FEAT-gutter-identity.md` (a
  prose-fold range placed in `_end_prose_run`)

## Background
Three integers track the live prose run: `_chunk_start_line`,
`_prose_run_start_line`, `_prose_anchor_line` (the viewport pin). Two
writers move lines above them, and each has its own copy of the shift rule:

- `_insert_after` calls `_shift_prose_rows_below(row, delta)`.
- `_rerender_tool_call_block` calls `shift_across_block` for the two run
  rows, then shifts the pin inline with a third rule: a swallowed pin row
  releases the pin instead of moving past the block.

An insert is a zero-width replacement, so one rule covers both writers.

The rows stay integers. Extmarks would not save the hand-shifting:
- `_insert_after` can insert at the run-start row. Its docstring says prose
  already in the buffer "wrote its `###` at the insert row". A mark there
  must move down on that insert, which needs right gravity. But
  `write_message_chunk` writes with `set_text` at column 0 of an empty last
  row, where the run starts. A right-gravity mark there moves past the new
  text.
- `_chunk_start_line` is set again after every streaming reflow
  (`start + #wrapped`), so a mark would gain nothing there.
- The pin sits inside the streaming reflow's replaced range, and a mark
  there collapses to an edge (neovim skill `references/rendering.md`). It
  would need to be placed again after each reflow, which is the same manual
  handling the integer gets now.

`_reflow_chunks(bufnr, flush_all)` branches on `flush_all` in five places.
Its one `true` caller is `_end_prose_run`, and its one streaming caller is
`write_message_chunk`. The two modes share only "rewrap these rows in place
and mark table row ends". Streaming picks a range that ends at the last
complete paragraph, stops before an open fence, rebuilds the live region,
and moves the marker forward. The final mode takes the rest of the buffer,
appends a closing fence, and releases the run. That final reflow is the end
of the run, so it belongs in `_end_prose_run`.

## Changes
### `message_writer.lua`
1. Replace `_shift_prose_rows_below(row, delta)`, the local
   `shift_across_block`, and the inline pin block in
   `_rerender_tool_call_block` with:
   ```lua
   --- @param first_row integer 0-indexed first replaced row
   --- @param old_end integer 0-indexed exclusive end of the replaced rows before the edit
   --- @param new_end integer 0-indexed exclusive end of the replacement after the edit
   function MessageWriter:_shift_prose_rows(first_row, old_end, new_end)
   ```
   The arguments are those of the `nvim_buf_set_lines` it follows.
   - A nil row stays nil.
   - A row before `first_row` stays.
   - A row at or after `old_end` moves by `new_end - old_end`.
   - A row in `[first_row, old_end)` is swallowed. The run rows go to
     `new_end`, the first row after the replacement, so nothing that tracks
     prose points into block lines. The pin is released with
     `_clear_prose_pin`: a pin is a promise about one row of content.
   The docstring keeps the "why" from both old docstrings.
   - `_insert_after`: `self:_shift_prose_rows(insert_row, insert_row, insert_row + #inserted)`.
   - `_rerender_tool_call_block`, after its `set_lines`:
     `self:_shift_prose_rows(start_row, old_end_row + 1, new_end_row + 1)`,
     without the `line_delta ~= 0` gate.
   - Two behaviour changes, both unreachable today (`write_tool_call_block`
     ends the prose run before it writes, so every live run row sits below
     every block that is laid out again):
     - A run row equal to the block's `start_row` was left in place. It now
       counts as swallowed, as the pin did already. This also matches
       `shift_across_block`'s docstring: "nothing tracking prose may point
       into block lines".
     - A replacement with no line-count change (`line_delta == 0`) left a
       swallowed row alone. It now moves the row past the block and
       releases the pin.
2. Split `_reflow_chunks(bufnr, flush_all)`:
   - `MessageWriter:_rewrap_rows(bufnr, first_row, end_row) -> string[] wrapped, boolean changed`.
     The first line of its docstring: "Wrap rows `[first_row, end_row)` in
     place and mark their table row ends." It reads the rows and wraps them
     with `_wrap_prose`. It calls `set_lines` only when the result differs,
     and applies `mark_table_row_ends`.
   - `_reflow_chunks(bufnr)` becomes `_reflow_complete_paragraphs(bufnr)`,
     the streaming case only. It finds the last blank row, clamps before an
     open fence, calls `_rewrap_rows`, calls `_rebuild_prose_region` when
     `changed`, and moves `_chunk_start_line` to `start + #wrapped`. Its
     docstring loses the `flush_all` paragraphs. The fence sentence now says
     the clamp keeps the marker outside an open fence so that
     `_end_prose_run`'s `unclosed_fence` sees the opener. The "Not on the
     flush path" comment goes. `write_message_chunk` calls the new name.
   - `_end_prose_run(bufnr)` takes over the flush, in today's order:
     1. capture `run_start`;
     2. clear the region decorations;
     3. set `_prose_run_start_line` and `_prose_region_ids` to nil;
     4. when `_chunk_start_line` is below the line count, call
        `_rewrap_rows` to the end of the buffer, and append
        `TextWrap.unclosed_fence(wrapped)` when that is non-nil;
     5. set `_chunk_start_line = nil` with no condition. The "stale marker
        corrupts the next turn's reflow" comment moves here;
     6. stamp the bracket;
     7. `end_with_one_blank`.
     Its docstring: "Every writer that interrupts prose calls this" drops
     "rather than the flushing reflow directly".
3. Field docstrings: `_chunk_start_line` and `_prose_run_start_line` say they
   are cleared by `_end_prose_run`. This replaces the whole of "cleared by
   every flushing reflow, which is to say wherever a prose run ends".

### Docs
- `session-lifecycle` skill, cross-turn table: the `_chunk_start_line`
  reset is `_end_prose_run`.

### Tests (`message_writer.test.lua`)
Write first, with all three rows set:
- `_shift_prose_rows` with a replacement:
  - rows above are unchanged;
  - rows below move by the delta;
  - rows inside the range: run rows at `new_end`, pin nil;
  - a row equal to `first_row` counts as swallowed;
  - a delta-0 replacement with a row inside it: run rows at `new_end`, pin
    nil.
- The insert form (`first_row == old_end`): a row at `first_row` moves.
Existing tests must pass unchanged: those listed under Relevant files, and the
integration flush test.

## Expected outcome
No behaviour change outside the two unreachable cases in change 1. Every
move of the prose run's rows goes through one rule. The end of a run is one
function, with no mode flag.

## Non-goals
- Prose rows tracked by extmarks (see Background).
- The streamed-code hard-wrap bug
  (`notes/bug-streamed-code-lines-get-hard-wrapped.md`). It changes the
  streaming clamp, which this plan moves unchanged. If it lands later, it
  edits `_reflow_complete_paragraphs`.
- `FEAT-gutter-identity.md`'s prose fold. If it lands later, it adds its range
  in `_end_prose_run`.

## Open questions
None.
