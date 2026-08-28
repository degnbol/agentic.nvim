# Plan: gutter identity glyphs

Master note for six units of work, of which 1 to 3 have shipped. Each remaining
unit note is self-contained; this one holds the rule they converge on, the
limitation they accept, and the order.

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

## Delivered

Units 1 to 3 have shipped; their notes are gone and the code is the reference.
The rule above is in force, not proposed.

1. Command notices — `/trust`, `/rename`, `/context`, model/provider switch and
   session resume render as glyph-signed headings instead of fabricated
   `agent_message_chunk`s. See `MessageWriter:write_notice` and `glyphs.lua`.
2. Gutter region signs — the tool-call kind glyph moved to the sign column, the
   prompt and body-bearing notices grew a region bracket, and the prompt's `---`
   separator is retired. See `ExtmarkBlock.render_block`/`render_rail`,
   `Renderer.render_decorations`, and `render_region_rail` in `message_writer`.
3. Closing summary bracket — the prose that closes a turn takes a `╭─` region,
   tracked by `_prose_run_start_line` and drawn by `render_prose_region` in
   `finalize_turn`. Shipped ahead of 5, so thinking is still prose and the
   bracket has to dodge it twice: skipped when the turn ends on a thought chunk,
   and re-anchored at the answer when a turn thinks and then answers. Unit 5
   retires both.

   Restored sessions carry no closing summary bracket: `replay_messages` writes
   agent prose through `write_message`, which starts no run, and finalizes no
   turn. Prompt and tool-block regions do survive a restore, so this is the one
   bracket that a resumed buffer is missing — the same gap unit 1's notices
   accept, and the fix is the same shape: replay would have to bracket at each
   user→agent boundary.

## Units and order

4 is independent. 6 needs 5; its own first phase needs nothing.

4. [`bug-mid-turn-prompt-splits-prose.md`](bug-mid-turn-prompt-splits-prose.md) —
   a submit mid-turn wedges its `##` heading into the streaming prose run.
   Deferring its *display* to the turn boundary is correct here precisely because
   the agent does not act on it until then — the opposite of a command notice,
   which takes effect immediately and so renders where it happened. Mostly
   pre-empted by
   [`refactor-unify-message-queues.md`](refactor-unify-message-queues.md), which
   makes `<CR>` tag instead of dispatch when the gate is closed; what remains is
   the forced `:w`/`:X` path. Decide whether it folds into that note.
5. [`feature-thinking-summary-line.md`](feature-thinking-summary-line.md) —
   thinking currently renders as ordinary prose, indistinguishable from the
   answer. Collapse a thought run to a single closed-fold row carrying the glyph
   and a character count, with no heading (a heading whose section holds a fence
   would pin the breadcrumb for the rest of the turn).
6. [`PLAN-hooks_in_chat.md`](PLAN-hooks_in_chat.md) — hook activity (injected
   context, timeouts) is invisible because the ACP bridge drops the hook lifecycle
   events; recover it from the CLI's transcript jsonl and render each record as
   one closed fold row. Takes 5's shape wholesale — `markdown-fold` body,
   `sign_text` glyph, no heading (a titled section over a fenced body would pin
   the breadcrumb, per `queries/agentic/context.scm`) — and extends the same
   per-kind foldtext dispatch, so it **needs 5** and is independent of 3 and 4. Its
   own phase 1 (the transcript reader) is pure file IO with no rendering, so it can
   run **at any point**. Separately it converts a site unit 1 left as prose:
   blocking-hook feedback arrives as a genuine `agent_message_chunk`, identifiable
   by a bridge-generated severity prefix — that part renders through
   `write_notice`.

## Glyph vocabulary

`glyphs.lua`. Nerd Font `nf-md-*`, never emoji, and every new glyph must avoid
the tool kinds 󰈈 󰏫 󰆍 󰍉 󰖟 󰚩 󰒓. `sign_text` must be
`glyph .. " "` — two cells, which is also what lets a wide-aspect glyph render
across both. 󰋚 history is reserved for a future rewind. 󰛢 hook is taken by unit 6.
