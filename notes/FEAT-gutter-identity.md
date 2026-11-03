# Plan: gutter identity glyphs
Status: reviewed (open questions)

## Background

### Rule

**The sign column says what a region is; the buffer text says what it contains.**
A region's opening row carries an identity sign, continuation rows `│`, the last
row `╰─`. Single-row regions carry the identity sign alone — the bracket is what
a region grows when it has more than one row, not a frame every region wears.

The chat window is `signcolumn=yes:1` (`ChatBuffer.win_opts`): one sign per row,
so a region bracket and an identity marker cannot share the opening row. Identity
wins; the `╭─` corner (`ExtmarkBlock.SIGNS.HEADER`) survives only for a region
with no identity to announce, which is prose.

`╰─` goes on the last row that draws it where it can be seen (`last_drawn_row` in
`message_writer.lua`): not a trailing blank, and not a fence delimiter, which
`TextWrap.is_fence_delimiter` conceals to zero height.

### Accepted limitation

treesitter-context renders the pinned node's buffer line only, so a gutter glyph
never reaches the breadcrumb: a pinned diff reads `` ### `path.lua` `` with no
read/edit distinction. `copy_extmarks` in the installed plugin's
`treesitter-context/render.lua` copies only `nvim.`-prefixed namespaces. Accepted
because a pinned block's kind is implied by what is on screen, and the blocks
whose kind is not self-evident are short enough to keep their heading in view.

### Glyph vocabulary

`glyphs.lua`. Nerd Font `nf-md-*`, never emoji, and every new glyph must avoid
the tool kinds 󰈈 󰏫 󰆍 󰍉 󰖟 󰚩 󰒓. `sign_text` must be
`glyph .. " "` — two cells, which is also what lets a wide-aspect glyph render
across both. 󰋚 history is reserved for a future rewind. 󰧑 `THINKING` (unit 5)
and 󰛢 `HOOK` and 󰛣 `HOOK_FAILED` (unit 6) are spent.

## Changes

### Foldable prose regions

A finished prose region folds on `zc`, open by default.

- **Fold source.** `queries/agentic/folds.scm` is the buffer's only fold query.
  It matches `code_fence_content` under a `fold$` info string, and its top
  comment rules out markdown's `(section)` (it would fold all prose, and misses a
  run with no `###` opener). No node spans a run — a run is sibling paragraphs —
  so the range comes from the writer. `_end_prose_run` discards the finished
  region's extmark ids, so the range cannot be read back by id. Approach:
  `_end_prose_run` places one range extmark (`end_row` set) per finished region
  in a namespace that `agentic.ui.folds` owns, and `ranges_in` returns those
  ranges next to the query matches. This is preferred over scanning
  `NS_DECORATIONS` for `╭─`/`╰─` because a `set_lines` collapses signs onto one
  row (`extmark_block.lua` header comment), and a range extmark tracks edits by
  itself.
- **Invalidation.** `agentic.ui.folds` keeps levels in a per-buffer state that
  only `on_bytes` and `on_changedtree` make dirty (`splice`, `watch`). Placing an
  extmark fires neither, and Vim does not re-run `foldexpr` for it. So
  `agentic.ui.folds` needs a public function to mark rows dirty, and the writer
  then calls `BufHelpers.recompute_folds(winid)` for each window showing the
  buffer, or arms `_rebuild_folds_after_insert` in insert mode.
- **Nesting.** `levels_of_ranges` nests folds by containment, so a `fold$` fence
  the agent writes inside prose nests under the prose fold. The module
  docstring's invariant (footprints nest or are disjoint) holds, because a run
  ends before any other block is appended. `fold_span` and `refresh` take a
  fold's footprint to include the row above its first row (an opening fence row
  for query folds); for a prose fold that row is the blank or `###` above the
  region, and must be counted the same way.
- **Fold range.** From the region's first prose row (the `╭─` row) through its
  `╰─` row, so the row a closed fold shows carries the region's sign.
- **Open by default.** `ChatBuffer.win_opts` pins `foldlevel = 99`, but a fold
  created after a closed one inherits the closed state, and prose often lands
  under a closed thought region. Open it explicitly with
  `_queue_fold(first_row, true)`, as `_decorate_collapsed_region` does for an
  open region.

### Blocking-hook feedback

Remaining from unit 6: feedback from a blocking hook arrives as a real
`agent_message_chunk` and renders as prose. A bridge-generated severity prefix
identifies it. No note owns it yet.

## Non-goals

- Prose regions in a replayed chat. `SessionResume.replay_messages` writes
  agent prose through `write_message`, which starts no prose run, so a replayed
  buffer has no `╭─` regions and no prose folds. Command notices are not in
  `ChatHistory` either. A fix would bracket each user→agent boundary in replay.
- Folding a live run. Its range changes with each reflow; it becomes foldable at
  `_end_prose_run`.

## Open questions

1. Design Q: what does a closed prose fold show? `Folds.foldtext` shows
   `··· N lines ···`, or leads with the fold's first row when the row above it
   carries an `NS_TITLED` mark (a mark meant for an opening fence row, which a
   prose fold does not have). Leading with the first prose row names what was
   folded; the bare count is shorter.
