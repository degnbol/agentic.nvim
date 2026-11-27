# Plan: one-row fold rule and collapsed-region layout
Status: spec
Priority: P3
Depends: REFACTOR-tool-block-rows.md

## Relevant files
- `lua/agentic/ui/folds.lua` — `ranges_in`: a fold forms only when
  `fold_last > fold_first`; `M.levels`
- `queries/agentic/folds.scm` — the `-fold`, `-foldnext` (the next fence is
  `console` or `console-fold` with content) and `-foldfence` patterns
- `lua/agentic/ui/tool_call_layout.lua` — `Section` (`fold`, `fold_through`
  docstrings), `Layout`, `assemble`, `M.build`, `output_fold_state`,
  `reason_section`, `output_section`, `prose_section`, `command_fold_state`,
  `BODIES.todowrite`, `diff_body`, `rejected_body`
- `lua/agentic/ui/tool_call_renderer.lua` — `apply_block_highlights`
  (handles `table_row_end`), `set_dim_range`
- `lua/agentic/ui/message_writer.lua` — `collapsed_region_lines`,
  `CollapsedRegionOpts`, `_decorate_collapsed_region`,
  `render_collapsed_region`, `_append_collapsed_region`,
  `_place_collapsed_region`, `flush_thought_run`, `write_hook_block`,
  `write_discovered_skills`, `write_hook_row`, `write_loaded_file`,
  `write_notice` (its `fold_body`), `_place_row`, `_append_row`,
  `_insert_after`, `_resolve_anchor`, `_paint_tool_call_block`, `_queue_fold`,
  `mark_table_row_ends`
- `lua/agentic/session_manager.lua` — a comment in `_finalize_turn` names
  `_append_collapsed_region`
- Tests: `tool_call_layout.test.lua` ("folds a one-row command closed by its
  fence", "gives a reject without agent text a one-row reason", "leaves a
  one-row switch_mode body unfolded"); `tool_call_renderer.test.lua`
  (`describe("block highlights")`); `message_writer.test.lua`
  (`describe("hook blocks")`, "leaves a titled one-row body open", "keeps
  write order across rows and hook regions", "places a prompt's hook block
  after it, then its rows", "opens a failed hook block after a closed one",
  "folds a failed one-row diff together with its reason", "underlines a
  table in a hook block's body", "underlines a table in a hook block placed
  under its call", the thought-run and notice tests); `folds.test.lua`
- `.claude/skills/rendering/SKILL.md` § Body folding
- `notes/FEAT-gutter-identity.md` (names the replaced methods)
- Skills: `rendering`, `follow`, `neovim` (`references/folding.md`)

## Background
`Folds.levels` forms a fold only when it spans more than one row, because
vim cannot close a one-line fold at `'foldminlines'` = 1. Writers guess this
rule again in ten places, each dropping `fold` for a one-row or empty body,
often with an "E490" comment:
- in the builders: `output_fold_state`, `reason_section`, `prose_section`,
  `BODIES.todowrite`, `diff_body` (twice), `rejected_body`;
- in `message_writer.lua`: `collapsed_region_lines` (`#body > 1`),
  `_decorate_collapsed_region` (`body_end > body_start`), and `write_notice`
  (`#fold_body > 1`).

`assemble` sees every section and the one after it, so it can apply the rule
once, as `Folds.levels` will.

A collapsed region (thinking, hook output, discovered skills) is a section:
a body, maybe fenced, a fold marker, maybe titled, maybe dimmed, with table
row ends. A notice's `fold_body` is a section too. `collapsed_region_lines`
and `write_notice` copy `assemble`'s fence and marker step.
`_decorate_collapsed_region` copies `_paint_tool_call_block`'s highlight,
titled and dim steps.

What a region does differently is real:
- its identity sign goes on its first body row;
- it has no header, footer or range extmark;
- its fold is queued once with `_queue_fold`, while a block's folds are
  tracked for re-renders.

`_place_row` and `_place_collapsed_region` are twins. Each schedules the
follow and resolves the anchor. When the anchor is found, each calls
`_insert_after` in an own edit and decorates. When it is not, each flushes
the thought run and appends: release the pin, end the prose run, append,
decorate.

The appends differ only in kind. A row joins the row group at the end
(`_append_row`, which leaves a pending section break pending). A region
takes the section break and a trailing blank (`_append_collapsed_region`).
That difference is the existing `PlacedKind` (`"row"`/`"region"`), which
`_insert_after` already takes. So there is one place-or-append, and the
append branches on kind.

## Changes
### `tool_call_layout.lua`
1. `assemble` decides whether each section's fold forms, with
   `local function fold_forms(section, next_section) -> boolean`. The
   docstring cites `Folds.levels` and the three `folds.scm` patterns. It
   returns true when `section.fold` is set, `section.lang` is set, and
   `#section.rows > 0`, and:
   - with no `fold_through`: `#section.rows > 1`;
   - with `"fence"`: always (the closing fence row is in the fold);
   - with `"next"`: `next_section` exists, `next_section.lang == "console"`,
     and `#next_section.rows > 0` (`@fold.end` needs fence content).
   When it returns false, `assemble` adds no marker and no `Layout.folds`
   entry.
2. `assemble` becomes `M.assemble(sections)` and no longer adds the footer.
   `M.build` adds `""` after it.
   - `Layout` docstring: indices are from the first row; the last row of
     `build`'s layout is the footer.
   - `assemble` docstring: drop "append the footer row".
   - `Section.fold`: "requested fold state; `assemble` adds the marker and a
     fold only when the fold forms (`fold_forms`)".
   - `Section.fold_through`: drop "so a one-row section folds too", and say
     what each value ends on.
3. `M.table_row_end_highlights(indices: integer[]) -> agentic.ui.ToolCallLayout.HighlightRange[]`
   turns 1-based row indices into `table_row_end` ranges. `prose_section`
   uses it in place of its loop.
4. Builders state policy only:
   - `output_fold_state(rows, max_lines)`:
     `max_lines > 0 and #rows > max_lines and "closed" or "open"`.
   - `reason_section`, `prose_section`, `BODIES.todowrite`: `fold = "closed"`.
   - `diff_body`: a failure sets `fold = "closed"` and `fold_through = "next"`;
     otherwise `fold = open and "open" or "closed"`.
   - `rejected_body`: `fold = "closed"` and `fold_through = "fence"`.
   - All "one-row … E490" comments go. `command_fold_state` keeps
     `#output == 0 → nil`: never hiding a command alone is policy.

### `tool_call_renderer.lua`
5. `apply_block_highlights(bufnr, start_row, layout)` becomes
   `M.apply_layout(bufnr, first_row, layout) -> integer|nil dim_id`. It
   places highlights, ANSI and match spans as now, plus the
   `Folds.NS_TITLED` marks and the dim range, which move from
   `_paint_tool_call_block`. Renderer requires `Folds` (no cycle: `folds.lua`
   requires only `markdown_guard` and `text_wrap`). `_paint_tool_call_block`
   calls it after `render_decorations` and appends `dim_id` to
   `decoration_extmark_ids`.

### `message_writer.lua`
6. `local function region_section(body, opts) -> agentic.ui.ToolCallLayout.Section`
   replaces `collapsed_region_lines`. It returns
   `{ rows = body, lang = #body > 1 and "markdown" or nil, fold = opts.open and "open" or "closed", titled = opts.titled, dim = not opts.undimmed, highlights = ToolCallLayout.table_row_end_highlights(opts.table_row_ends or {}) }`.
   The `#body > 1` here decides the fence, not the fold: a fence around one
   unfolded row is worse than the row. The reason comes from today's
   docstring.
7. `MessageWriter:_lay_out_region(body, sign, opts) -> string[] lines, fun(bufnr: integer, first_row: integer) decorate`
   replaces `_decorate_collapsed_region`.
   - It builds `section = region_section(body, opts)` and
     `layout = ToolCallLayout.assemble({ section })`.
   - `decorate` calls `render_collapsed_region` on the body rows, from
     `first_row + (section.lang and 1 or 0)` for `#body` rows. It calls
     `Renderer.apply_layout(bufnr, first_row, layout)`, and
     `_queue_fold(first_row + fold.anchor, fold.state == "open")` for each
     `layout.folds` entry.
   - The "opened explicitly" comment moves here. `mark_table_row_ends`
     stays only for the prose reflow.
8. `MessageWriter:_place_at(anchor, kind, lines, decorate)` replaces
   `_place_row` and the place-or-append half of `_place_collapsed_region`.
   It calls `_schedule_follow` and `_resolve_anchor`. When the anchor is
   found, it calls `_insert_after(placed, last_row, lines, kind)` in
   `_own_edit`, then `decorate(bufnr, first_row)`. When it is not, it calls
   `flush_thought_run`, then `_append_placed(kind, lines, decorate)`.
9. `MessageWriter:_append_placed(kind, lines, decorate)` replaces
   `_append_collapsed_region` and the append half of `_place_row`.
   - It calls `_release_prose_pin` and `_schedule_follow`, then, in
     `_own_edit`, `_end_prose_run`. Then it finds the first row:
     - `"row"`: `_append_row(lines)`;
     - `"region"`: `_take_section_break()`, `lines` and `""` are appended,
       and the first row is derived after the append (the empty-buffer
       comment stays).
   - Then it calls `decorate`.
   - `_append_row(row)` becomes `_append_row(lines)`. A `"row"` placement is
     one or more lines (`PlacedKind`). Its `_insert_after` call already
     takes a list. The new-group branch appends `lines` and `""`, and the
     group mark goes on the last line.
10. Callers bind `_lay_out_region`'s two results to locals before passing
    them on:
    - `_place_collapsed_region` becomes `_place_region` with the same
      parameters. It keeps the empty-body return, the title prepend with the
      `table_row_ends` shift, and `open = opts.open or #body == 1`. Its
      docstring says why: the clause reads `#body` before the title is
      prepended, so a titled one-row body is two rows and does fold, and it
      stays open. Then
      `local lines, decorate = self:_lay_out_region(body, sign, opts)` and
      `self:_place_at(anchor, "region", lines, decorate)`.
    - `flush_thought_run`: the same, with `_append_placed("region", lines, decorate)`.
    - `write_hook_row` and `write_loaded_file` call
      `self:_place_at(anchor, "row", { ROW_INDENT .. text }, decorate)`.
      `local ROW_INDENT = "  "` takes the indent comment from `_place_row`.
    - `write_hook_block` and `write_discovered_skills` call `_place_region`.
11. `write_notice`: the notice is `ToolCallLayout.assemble` over two
    sections:
    - the heading, detail and body rows, unfenced;
    - `fold_body`, when non-empty, as
      `{ rows = fold_body, lang = "markdown", fold = "closed", highlights = ToolCallLayout.table_row_end_highlights(table_row_ends) }`.
      It stays fenced even at one row (the comment stays).
    Then `""` is appended. After the append, `Renderer.apply_layout(bufnr, heading_row, layout)`
    runs, plus `_queue_fold` per `layout.folds` entry. The detail row's own
    `set_dim_range` stays: a layout holds one dimmed range, and the fold
    body is not dimmed. The notice's placement and its
    `NS_USER_ACTIONS` mark, `_notices` entry and rail do not change.

### Docs and notes
12. `rendering` skill § Body folding:
    - thought runs are written through `_append_placed`; hook output and
      discovered skills through `_place_region`;
    - the fold-trigger paragraph adds that `assemble` drops a requested
      fold that would not form.
13. The `session_manager.lua` `_finalize_turn` comment: `_append_placed`.
14. `notes/FEAT-gutter-identity.md`: `_decorate_collapsed_region` →
    `_lay_out_region`.

### Tests
Write first, in `tool_call_layout.test.lua`. Each case writes
`assemble(sections).lines` to a buffer, starts the `agentic` parser, and
checks that the fold starts from `Folds.levels` are exactly
`first + fold.anchor` for each `Layout.folds` entry, and that no other fold
starts:
- 0, 1 and 2 rows, each with `fold_through` nil, `"next"` and `"fence"`;
- `"next"` before a `console` section with rows, a `console` section with
  zero rows, an unfenced section, and a fenced section that is not
  `console`;
- an unfenced section with `fold` set;
- a titled section.

Also: `table_row_end_highlights({ 1, 3 })`; and in `tool_call_renderer.test.lua`,
`apply_layout` returns the dim id and sets the titled marks.

Existing tests that must pass unchanged: those under Relevant files, all
hook, thought, notice and table-region tests in `message_writer.test.lua`,
and `folds.test.lua`.

## Expected outcome
- The rendered output does not change. A one-row notice fold body now carries
  a plain `markdown` fence. Before, it had a `markdown-fold` marker that gave
  no fold. The marker is concealed, so this is not visible.
- The one-row rule lives in `Folds.levels`, mirrored once in `assemble`, and
  tests check that mirror against `Folds.levels`.
- Collapsed regions and notice fold bodies are laid out by the code that lays
  out tool call sections.
- Rows and regions are placed by one function.

## Non-goals
- Treesitter injection materialising for regions (blocks only, as today).
- Tracking region folds for re-render; a region is written once.
- The append preamble (`_release_prose_pin`, `_schedule_follow`,
  `_own_edit` + `_end_prose_run`) that `write_notice`, `write_error_action`,
  `write_subagent_heading`, `write_tool_call_block`, `finalize_turn` and
  `end_runs` repeat. Each writer's body and placement differ, and some flush
  the thought run while others do not. A shared "end the run, then write at
  the end" helper is a separate unit of work. It would generalise
  `_append_placed`.

## Open questions
None.
