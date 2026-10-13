# Bug: the unmatched-diff fallback escapes its fence

Line numbers against `cc07515` + working tree.

## Mechanism

In the diff branch of `prepare_block_lines`, the fence width comes from
`diff_blocks` (`fence_content` → `M.safe_fence`, `tool_call_renderer.lua:1158-1163`).
The fallback block for an Edit whose `old_string` is not in the file is
appended to `diff_blocks` later, at `:1233-1253`. On that path `fence_content`
is empty, so `safe_fence` returns a bare ```` ``` ````, while the body comes
directly from `diff.old`/`diff.new`. A diff that contains a fence line (an edit
to markdown with code examples, or to this repo's own docs) closes the outer
fence at its first body line. This breaks conceal, the `-difffold` fold, and
every `block_col_hl` extmark below it.

Reproduced headless: `old = {"```lua", "local x = 1", "```"}`,
`new = {"```python", "y = 2", "```"}` against a file that does not contain the
old text renders ```` ```markdown-difffold ```` followed by a body whose first
line closes it.

## Fix

Move the `#diff_blocks == 0 and #diff.old > 0` synthesis from `:1233-1253` to
the start of the `elseif tool_call_block.diff` branch (`:1144`), before
`fence_content` at `:1158`.

Both limits are necessary:

- **After the `cached_diff_blocks` capture and the `head_line` assignment
  (`:897-909`)** — `cached_diff_blocks` feeds `diff_jump`, and the fallback
  block's `start_line`/`end_line` index nothing. Caching it would send `gf` to
  false coordinates, and the head would name line 1. The diff branch starts
  after both, so this limit holds.
- **Before `:1158`** — that is the purpose of the move.

Nothing between `:1144` and `:1233` reads `diff_blocks`: `lang` (`:1153`)
reads `source_lines`/`diff.new`, `collapse` (`:1180`) reads `is_create` and
`diff.new`, and the reparse-size gate (`:1202-1206`) reads
`source_lines`/`diff.new`. So the move changes only the fence width.
`unmatched = true` and the `not block.unmatched` gate at `:1266` are not
affected.

## Why not fix it in `extract_diff_blocks`

`ExtractOpts.strict` (`tool_call_diff.lua:24`) is documented as "don't return
fallback blocks if match fails", but no caller passes it and nothing reads it.
It is dead because the fallback is in the renderer. Moving the synthesis there
would make `strict` live and put the block ahead of every consumer. It also
adds two changes this fix does not need: a `not blocks[1].unmatched` guard at
the `cached_diff_blocks` capture, and `minimize_diff_blocks` running over a
synthetic block. Keep the move local to the renderer; examine `strict`
separately.

## Tests

In `tool_call_renderer.test.lua`: an edit with a real path, a
`read_from_buffer_or_disk` stub (and the `read_from_disk` stub, which
`extract_diff_blocks` tries next) returning content that does **not** contain
`diff.old`, and a fence-bearing `diff.old`/`diff.new`. Assert the opening fence
is longer than the longest backtick run in the body.

**The fence lines must differ between old and new** (e.g. ```` ```lua ```` vs
```` ```python ````). `filter_unchanged_lines` drops identical pairs, so a test
with the same fence on both sides renders a clean body and passes against the
current code.

Two nits in the same test file:

- `:893`: `assert.equal(0, (render_counting_buffers(block)))` — the outer
  parentheses truncate to the first return, with no comment. Name both
  returns instead.
- `:905-907`: the `read_stub:invokes` in the empty-path case is dead.
  `extract_diff_blocks` returns early on `path == ""`
  (`tool_call_diff.lua:51-53`) before any read.
