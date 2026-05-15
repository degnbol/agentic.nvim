# Plan: line numbers in Edit tool diff previews

## Problem

When the Edit tool moves a line within a file (or makes a small change in
a long file), the rendered diff in the chat panel gives no positional
anchor. The user sees the `+`/`-` lines but can't tell *where* in the
file the change happened. For moves in particular the diff is doubly
unhelpful: identical content on both sides, no line numbers, no way to
distinguish "moved from where to where".

## Constraints

- **No line numbers in the ACP Edit payload.** The Edit tool input is
  string-based: `{ file_path, old_string, new_string, replace_all? }`.
- **`structuredPatch` is not forwarded.** The SDK's `FileEditOutput`
  carries `oldStart`/`newStart`/`oldLines`/`newLines`, but the
  claude-agent-acp bridge flattens `rawOutput` to a plain success
  string before sending it to ACP clients. See
  `.claude/skills/acp/references/claude-agent.md` § "Edit tool".
- **Yank should stay clean.** The line numbers must not become part of
  buffer text — copying a diff line should give back the file content
  verbatim, not "`42  foo = bar`".

## Existing infrastructure to reuse

`SessionManager:_record_pending_edit_range` (called at the initial
`tool_call`, before the SDK applies the edit) reads the file and finds
`diff.old` as a **unique** line subsequence. The start line is stashed
in `PermissionManager._pending_edits`. On the matching `tool_call_update`
with `status: "completed"`, `finalize_edit_range` promotes it to
`_edit_records` with `end_line = start_line + #diff.new - 1`.

Built for the `/trust` scope safety check, but the captured `start_line`
is exactly what a diff renderer would want.

### Limitations of synthesis

- **`replace_all` and non-unique matches.** Claude's Edit tool normally
  enforces `old_string` uniqueness at execution time, so a non-unique
  match at record time means the file has already shifted — we skip
  recording. For `replace_all=true` edits the diff contains multiple
  non-contiguous changes; the single-range model doesn't fit.
- **Replay from saved session.** Line ranges are captured at live
  `tool_call` time. When a session loads from JSON the file may have
  shifted (or not exist), so no range is available unless we serialise
  it alongside the tool call. The pre-edit content is recoverable from
  `diff.old`, but the post-edit line position is not.

## Rendering options

### Considered and rejected

- **Sign column (`sign_text` extmark).** Collides with the existing
  tool-call block borders (╭─ │ ╰─). Would force a choice per diff line:
  border or line number.
- **Number column via virt_text.** Not a thing — no extmark hook
  renders virtual text inside the number column. The only number-column
  extmark options are `number_hl_group` (highlights the existing number)
  and `line_hl_group` (highlights the whole line).
- **Multi-stacked signs (`signcolumn=yes:2`).** Widens the gutter,
  taking horizontal space from chat content. Not free, not invisible.
- **EOL virtual text.** Unintuitive — line numbers belong on the left.

### Leading candidate: `statuscolumn`

The only mechanism that renders arbitrary content in the number column
area. Set per chat-buffer; the function decides per line whether to
emit a line number, a border glyph, or both.

Open questions:

- **Coexistence with block borders.** The borders currently live in
  the sign column. With `statuscolumn`, the function would render
  both — borders for non-diff lines, line numbers for diff lines —
  on the same row. Does the sign column still need to carry borders?
- **Width budget.** Line numbers up to 5 digits + a separator + 1
  border glyph ≈ 7 cols. Acceptable for the chat panel.

## Open questions before implementation

1. **`replace_all` edits.** Skip line numbers entirely, or annotate
   only the first hunk?
2. **Replays.** Persist the captured range in the session JSON, or
   accept "no line numbers on replay"?
3. **Old-side line number.** The `old_start` is also known at record
   time but isn't currently stored. Worth capturing if we want to
   show "moved from line N → line M" explicitly for move-detected
   diffs.
4. **Move detection itself.** Is a move worth a dedicated rendering
   (e.g. "moved ↑12 lines") rather than just two annotated ranges?
   Heuristic: `diff.old == diff.new` content with different positions.
