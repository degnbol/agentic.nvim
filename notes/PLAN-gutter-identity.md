# Plan: gutter identity glyphs

Master note for six units of work: 1 to 3 and 5 have shipped, 4 has been handed
off, and 6 is partly done. Its note is self-contained; this one holds the rule
they converge on, the limitation they accept, and the order.

## The rule

**The sign column says what a region is; the buffer text says what it contains.**
A region's opening row carries an identity sign, continuation rows `│`, the last
row `╰─`. Single-row regions carry the identity sign alone — the bracket is what
a region grows when it has more than one row, not a frame every region wears.

The rule is forced by the chat window being `signcolumn=yes:1` — one sign per
row, so a region bracket and an identity marker cannot share the opening row and
one of the two meanings had to leave the gutter. Identity won it; the `╭─` corner
survives only for a region with no identity to announce, which is prose.

`╰─` goes on the last row that draws it where it can be seen (`last_drawn_row` in
`message_writer`): not a trailing blank, which has nothing to close over, and not
a fence delimiter, which `TextWrap.is_fence_delimiter` conceals to zero height so
the corner is never drawn at all. Interior rows of both kinds need no such care —
a zero-height row leaves no gap in the rail.

## The accepted limitation

treesitter-context renders the pinned node's buffer line only, so a gutter glyph
never reaches the breadcrumb: a pinned diff reads `` ### `path.lua` `` with no
read/edit distinction. Verified against the installed plugin (`copy_extmarks`
filters to `nvim.`-prefixed namespaces and its opts whitelist omits the sign
fields); getting it in there means patching upstream. Accepted because a pinned
block's kind is implied by what is on screen, and the blocks whose kind is not
self-evident are short enough to keep their heading in view.

## Closed

Units 1 to 3 and 5 have shipped; their notes are gone and the code is the
reference. The rule above is in force, not proposed. Unit 4 turned out to hold
no rendering work and left for the note that owns the submit paths.

1. Command notices — `/trust`, `/rename`, `/context`, model/provider switch and
   session resume render as glyph-signed headings instead of fabricated
   `agent_message_chunk`s. See `MessageWriter:write_notice` and `glyphs.lua`.
2. Gutter region signs — the tool-call kind glyph moved to the sign column, the
   prompt and body-bearing notices grew a region bracket, and the prompt's `---`
   separator is retired. See `ExtmarkBlock.render_block`/`render_rail`,
   `Renderer.render_decorations`, and `render_region_rail` in `message_writer`.
3. Closing summary bracket — the prose that closes a turn takes a `╭─` region,
   tracked by `_prose_run_start_line` and drawn by `render_prose_region` in
   `finalize_turn`. Its scope is superseded by unit 7, which brackets every prose
   run: the reason given here for confining it to one run per turn does not hold.

   Restored sessions carry no closing summary bracket: `replay_messages` writes
   agent prose through `write_message`, which starts no run, and finalizes no
   turn. Prompt and tool-block regions do survive a restore, so this is the one
   bracket that a resumed buffer is missing — the same gap unit 1's notices
   accept, and the fix is the same shape: replay would have to bracket at each
   user→agent boundary.

4. Mid-turn prompt splitting the prose run — folded into
   [`refactor-unify-message-queues.md`](refactor-unify-message-queues.md) §§ "One
   submit rule" and "Intended consequences". Nothing was left for the renderer:
   `write_user_prompt` already ends the run it interrupts (its
   `_reflow_chunks(bufnr, true)` drops `_prose_run_start_line`), so unit 3's
   bracket never spans the wedge, and the residual paragraph split is the cost
   `write_notice` documents and accepts. What remained hangs off the gate, so it
   went with it: whether a forced mid-turn submit sends at all, the concurrent
   `_dispatch_turn` state clobbering that follows if it does, and the bottom-pinned
   preview a *deferred* prompt gets while it waits.

5. Collapsed thought runs — thinking is buffered out of the prose path and
   rendered as one dimmed `markdown-fold` block closed at write, carrying 󰧑 on
   its first body row. See `MessageWriter:flush_thought_run` and `sign_at` /
   `foldtext` in `folds.lua`. Fixing the fold close that insert mode used to
   swallow came with it (`_retry_folds_on_insert_leave`), which repairs sidecar
   bodies too.

## Units and order

6. [`PLAN-hooks_in_chat.md`](PLAN-hooks_in_chat.md) — hook activity (injected
   context, timeouts) is invisible because the ACP bridge drops the hook lifecycle
   events; recover it from the CLI's transcript jsonl and render each record as
   one closed fold row. Injected context has shipped: it took 5's shape wholesale,
   and the two now share `MessageWriter:_write_collapsed_region`. Still open there:
   failures and unrecognised output, which need a second glyph, and persistence.
   Separately it converts a site unit 1 left as prose: blocking-hook feedback
   arrives as a genuine `agent_message_chunk`, identifiable by a bridge-generated
   severity prefix — that part renders through `write_notice`.

7. [`feature-prose-run-regions.md`](feature-prose-run-regions.md) — bracket every
   prose run rather than only the turn's last, gated on the run holding more than
   one paragraph, and draw it live instead of at turn end. Revises unit 3's scope
   and fixes the subagents pane, which has never drawn a summary bracket because
   its runs end at a Task divider rather than at `finalize_turn`. No new glyph:
   prose opens on the plain `╭─`.

8. Foldable prose regions — a prose region should fold on `zc`, open by default.
   After unit 7: the fold wants the region's range, so it needs the region to
   exist and be stable first.

   The fold *source* is the work. `folds.scm` is the buffer's only one and it
   matches `code_fence_content` under a `fold$` info string; prose has no fence,
   and no node spans a run — a run is a sequence of sibling paragraphs. Markdown's
   `(section)` is ruled out by that query's own top comment (sections nest, and
   `folds.lua` flattens every match to level 1), and would anyway miss a run with
   no `###` opener, which is the first prose of every turn. So the region becomes
   the fold: overlay the run's rows onto `M.levels`'s per-line array, read from
   the signs already placed.

   Three things that need deciding rather than assuming: `M.levels` caches on
   `b:changedtick` and placing an extmark does not bump it, so the render needs an
   explicit invalidation rather than relying on text landing afterwards; the
   non-nesting invariant holds by construction unless an agent writes a `fold$`
   fence inside prose; and `fence_source`'s "the row above a fold is always its
   fence" stops being true. Open-by-default is nearly free — `chat_win_opts` pins
   `foldlevel = 99` — but a fold created after a closed one still inherits the
   closed state, and prose lands directly beneath closed thought runs constantly,
   so it needs the same explicit `_open_fold` a diff gets.

## Glyph vocabulary

`glyphs.lua`. Nerd Font `nf-md-*`, never emoji, and every new glyph must avoid
the tool kinds 󰈈 󰏫 󰆍 󰍉 󰖟 󰚩 󰒓. `sign_text` must be
`glyph .. " "` — two cells, which is also what lets a wide-aspect glyph render
across both. 󰋚 history is reserved for a future rewind. 󰧑 thinking (unit 5) and
󰛢 hook (unit 6) are spent; unit 6's failure rows still need one.
