# Plan: one reader of a tool call block's rows; the diff freeze recorded on the block
Status: reviewed spec
Priority: P3
Depends: REFACTOR-prose-run-rows.md

## Relevant files
- `lua/agentic/ui/tool_call_renderer.lua` — `NS_TOOL_BLOCKS`
- `lua/agentic/ui/tool_call_layout.lua` — `assemble` (always appends the
  footer row)
- `lua/agentic/ui/message_writer.lua` — `_block_rows`, `tool_call_row`,
  `_scroll`, `_resolve_anchor`, `_rerender_tool_call_block`,
  `update_tool_call_block`, `set_output_tail`, `_paint_tool_call_block`,
  `nonfinal_tool_call_ids`, `agentic.ui.MessageWriter.ToolCallBlock`
  (`cached_diff_blocks`)
- `lua/agentic/ui/permission_highlight.lua` — `block_span`
- `lua/agentic/ui/diff_jump.lua` — `find_block_at_row`
- Tests: `tool_call_renderer.test.lua`; `message_writer.test.lua`
  (`describe("collapsed extmark handling")`, "appends when the anchor's
  range has collapsed", `describe("a diff rejected while pending")`, "closes
  the diff and shows the reason when the edit fails", "re-lays out with the
  diff closed and a reason section"); `diff_jump.test.lua`
  (`describe("find_block_at_row")`); `session_manager.test.lua`
  (`chat_reads_stopped` uses `_block_rows`' second return);
  `tests/integration/test_subagent_inputs.lua` (calls `writer:_block_rows`
  for the start row)
- `.claude/skills/rendering/SKILL.md` § Update-path invariants
- Skills: `rendering`, `provider-system` (diffs immutable after first render)

## Background
Five places read the `NS_TOOL_BLOCKS` range of a block with
`nvim_buf_get_extmark_by_id(..., { details = true })`, and each checks the
result differently:

| Site | Absent or no `end_row` | `start >= end` (collapsed) |
|---|---|---|
| `MessageWriter:_block_rows` | nil | returned as rows |
| `_resolve_anchor` (inline, "the same sanity gate") | nil | nil |
| `_rerender_tool_call_block` (inline) | WARN notify, keep tracker | debug-file log, drop tracker |
| `permission_highlight.block_span` | nil | returned as rows |
| `diff_jump.find_block_at_row` (inline) | skip | matched |

A block has at least two rows: `assemble` always appends the footer row
after a head of one or more rows. So a collapsed range never holds a block,
and one reader returns nil for every range that does not address one. The
renderer owns the namespace, so the reader goes there.

`_rerender_tool_call_block` then has two failure outcomes for one fact: the
tracker can no longer find its rows. A lost mark keeps a tracker that can
never update again. A collapsed one is reported only to the debug file,
which hides it. One outcome replaces both: drop the tracker and report it.
This is safe because only `MessageWriter:reset` clears `NS_TOOL_BLOCKS`, and
it empties `tool_call_blocks` in the same call.

`_rerender_tool_call_block(tracker, diff_frozen)` gets "the diff was laid out
before" from its callers. `update_tool_call_block` reads
`tracker.diff ~= nil` before it merges the update. `set_output_tail` reads it
with nothing to merge. Both read whether the last layout written to the
block, or confirmed equal to it, held a diff. So the write path records that
on the block.

## Changes
### `tool_call_renderer.lua`
1. Add, next to `NS_TOOL_BLOCKS`:
   ```lua
   --- @param bufnr integer
   --- @param extmark_id integer|nil
   --- @return integer|nil start_row 0-indexed header row; nil when the range is absent, deleted or collapsed
   --- @return integer|nil end_row 0-indexed footer row
   function M.block_rows(bufnr, extmark_id)
   ```
   The docstring says why a collapsed range is nil: `assemble` gives every
   block a head and a footer.

### `message_writer.lua`
2. Delete `MessageWriter:_block_rows`. `tool_call_row` and `_scroll` call
   `Renderer.block_rows(self.bufnr, block.extmark_id)`.
3. `_resolve_anchor`: the inline read and its "same sanity gate" comment
   become `last_row = select(2, Renderer.block_rows(self.bufnr, tracker.extmark_id))`.
4. `_rerender_tool_call_block(tracker)` makes one `Renderer.block_rows` call.
   On nil it deletes `tracker.placed.mark_id`, drops the tracker, and calls
   `Logger.notify("Tool call extmark lost: <id>", WARN, { title = "Agentic sync: extmark lost" })`, today's text. The branch is not expected to run: only `MessageWriter:reset` clears `NS_TOOL_BLOCKS`, and it empties `tool_call_blocks` in the same call.
   This replaces the two WARN branches and the `debug_to_file` branch.
   - The `diff_frozen` parameter goes. The freeze test reads
     `tracker.diff_laid_out`.
   - Docstring: "Drops the tracker when its range no longer addresses a
     block".
5. `ToolCallBlock` gains
   `--- @field diff_laid_out? boolean The last layout written over the block's rows, or found equal to them, was built with a diff`.
   - It is set to `block.diff ~= nil` in two places: in
     `_paint_tool_call_block`, and in the content-unchanged branch of
     `_rerender_tool_call_block`. The second matters for a first diff whose
     hunks do not match: its section has zero rows, so the rows compare
     equal and paint never runs.
   - The `vim.tbl_deep_extend` merge in `update_tool_call_block` keeps the
     field, because no update carries it.
   - It is not in `ChatHistory`'s `TOOL_CALL_FIELDS`: a replay lays the block
     out again.
6. `update_tool_call_block`: remove `already_has_diff`. `set_output_tail`:
   call without the second argument.
7. `nonfinal_tool_call_ids` docstring: "drops a tracker outright when its
   range no longer addresses a block".

### Other readers
8. `permission_highlight.lua`: delete `block_span`; call `Renderer.block_rows`.
9. `diff_jump.find_block_at_row`: read rows with `Renderer.block_rows`.

### Docs
10. `rendering` skill § Update-path invariants:
    - First bullet: "If it no longer addresses a block (absent, or
      `start >= end`), drop the tracker with a WARN".
    - Third bullet: "`already_has_diff` gates this" → "`diff_laid_out`
      gates this".

### Tests
Write first:
- `tool_call_renderer.test.lua`, new `describe("block_rows")`: a nil id, a
  deleted mark, a collapsed range, a valid range.
- `message_writer.test.lua` `describe("collapsed extmark handling")`: also
  assert a notify with the title `Agentic sync: extmark lost`. Add a deleted
  range extmark case: the tracker is dropped with the same notify. Today's
  code keeps that tracker.
- Freeze, in three cases:
  - A second update with a changed `diff` and status `completed` refreshes
    only the footer.
  - An update that brings the first diff lays the block out again.
  - A first diff whose hunks do not match, with unchanged rows, then a
    `completed` update with a changed diff: only the footer is refreshed.
Update:
- `session_manager.test.lua` `chat_reads_stopped`:
  `local _, footer_row = Renderer.block_rows(bufnr, writer.tool_call_blocks["tc-bg"].extmark_id)`.
- `tests/integration/test_subagent_inputs.lua`: `writer:tool_call_row("t9")`.
Existing tests that must pass: `diff_jump.test.lua` `find_block_at_row` and
the message_writer diff tests listed above.

## Expected outcome
- Every reader treats a range that does not address a block the same way.
  A collapsed range now gives no rows to `_scroll`, so a held block is
  treated as unplaced. It also gives no rows to `permission_highlight` and
  matches nothing in `find_block_at_row`.
- When an update cannot find its block, the tracker is dropped and a WARN is
  shown. Before, a lost mark kept a dead tracker, and a collapsed one was
  logged only to the debug file.
- After a drop, later updates for that id warn "Tool call update for unknown
  block". `_apply_side_tool_call` holds side fields until the turn ends.
  `PermissionManager` loses the `tracker.argument` fallback. This is what
  happens after a collapse today.
- Diff freezing works as before, from one field.

## Non-goals
- `cached_diff_blocks`. It is set only when hunks matched, so it is not the
  freeze fact. It stays the `diff_jump` cache.
- The status-footer write at three sites. These are three calls of the one
  writer, `Renderer.apply_status_footer`, on three paths. Nothing is
  duplicated.
- The `old_end_row > line_count` check in the frozen path.
- Any change to when a diff is laid out again (`failed`, rejection,
  `ended_as`).

