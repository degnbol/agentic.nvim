# Bug: the unmatched-diff fallback escapes its fence

Found reviewing `47f46a3` + `e3c0710`. Line numbers are against `50ed666`.

## Mechanism

`prepare_block_lines` computes the fence width from `diff_blocks`
(`tool_call_renderer.lua:730-735`), but the fallback block for an Edit whose
`old_string` isn't in the file is appended 80 lines later, at `:815-831`. On
that path `fence_content` is empty, so `safe_fence` returns a bare ```` ``` ````
while the body comes straight from `diff.old`/`diff.new`. A diff containing a
fence line — editing markdown with code examples, or this repo's own docs —
closes the outer fence at its first body line, which breaks conceal, the
`-difffold` fold, and every `block_col_hl` extmark below it.

Reproduced headless: `old = {"```lua", "local x = 1", "```"}`,
`new = {"```python", "y = 2", "```"}` against a file not containing the old text
renders ```` ```markdown-difffold ```` followed by a body whose first line
closes it.

## Fix

Move the `#diff_blocks == 0 and #diff.old > 0` synthesis from `:815-831` to just
after the `cached_diff_blocks` capture at `:715`.

Both boundaries are load-bearing:

- **After `:713-715`**, not before — `cached_diff_blocks` feeds `diff_jump`, and
  the fallback block's `start_line`/`end_line` index nothing, so caching it
  would send `gf` to fabricated coordinates.
- **Before `:730`** — that is the whole point.

Nothing between `:715` and `:815` reads `diff_blocks` (`lang` at `:725` reads
`source_lines`/`diff.new`; `is_create` at `:755` and the reparse-size gate at
`:780` read `source_lines`/`diff.old`), so the move changes only the fence
width. `unmatched = true` and the `not block.unmatched` gate at `:844` are
unaffected.

## Why not fix it in `extract_diff_blocks`

`ExtractOpts.strict` (`tool_call_diff.lua:24`) is documented as "don't return
fallback blocks if match fails" and passed by `diff_preview.lua:265`, but is
never read — dead precisely because the fallback lives in the renderer. Moving
the synthesis there would make `strict` live and put the block ahead of every
consumer rather than one more of them. It also drags in two changes this fix
doesn't need: a `not blocks[1].unmatched` guard at the `cached_diff_blocks`
capture, and `minimize_diff_blocks` running over a fabricated block. Keep the
renderer-local move; revisit `strict` on its own.

## Tests

In `tool_call_renderer.test.lua`: an edit with a real path, a
`read_from_buffer_or_disk` stub returning content that does **not** contain
`diff.old`, and a fence-bearing `diff.old`/`diff.new`. Assert the opening fence
is longer than the longest backtick run in the body.

**The fence lines must differ between old and new** (e.g. ```` ```lua ```` vs
```` ```python ````). `filter_unchanged_lines` drops identical pairs, so a test
with the same fence on both sides renders a clean body and passes against the
unfixed tree.

Two nits in the same test file while there:

- `:265`: `assert.equal(0, (render_counting_buffers(block)))` — the outer parens
  are load-bearing truncation with no comment. Name both returns instead.
- `:277`: the `read_stub:invokes` in the empty-path case is dead;
  `extract_diff_blocks` early-returns on `path == ""` (`tool_call_diff.lua:51-53`)
  before any read.
