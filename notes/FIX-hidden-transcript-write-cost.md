# Plan: Tool call writes cost O(buffer) in a large chat buffer
Status: reviewed spec
Priority: P1
Depends:

## Relevant files
- `lua/agentic/ui/fence_rows.lua` — `FenceRows:sync` (the `widened` map)
- `lua/agentic/ui/message_writer.lua` — `materialize_injections`, its one
  caller `_paint_tool_call_block`
- `lua/agentic/ui/folds.lua` — module docstring (lines 20–21)
- `lua/agentic/ui/fence_rows.test.lua`, `lua/agentic/ui/message_writer.test.lua`,
  `tests/integration/test_chat_injections.lua` (pattern for parse assertions)
- Skills: `implement`, `rendering`, `neovim` (`references/treesitter-integration.md`)

## Background
A skeptic's transcript (`BackgroundSession`) gets every check of its
session, so it grows for the whole main session. A live one had 33,032
lines, with no window showing it. While the skeptics ran, typing in the
input lagged.

Measured with that buffer's text in a headless nvim, through
`AgentView:write_tool_call` plus a completing `update_tool_call`:

| Transcript | Per tool call |
|---|---|
| empty | 8 ms |
| 33k lines | 570 ms median |
| 33k, cause 1 fixed | 179 ms |
| 33k, causes 1 and 2 fixed | 6 ms |

A message chunk costs 0.23 ms at 33k lines; only tool call blocks hit
the two causes. Skeptics make many tool calls (web searches), so each
one blocked the main loop for about half a second.

1. `FenceRows:sync` widens each dirty span to the fenced blocks it meets
   with `math.min(first, block:start())`. `TSNode:start()` returns row,
   column and byte, so the minimum is the column, 0 (or the indent): any
   edit that meets a fenced block re-scans the buffer from the top,
   including a string parse of every markdown fence body.
   `delimiter_rows` already writes `(node:start())`.
2. `materialize_injections` runs a range parse on every tool call
   block paint (two per tool call). Core's injection pass costs about
   100 ms per range parse at 33k lines, whatever the range. The parse
   only prevents unhighlighted fences in a window on view. Nothing else
   reads the injected trees: folds, `FenceRows`, `buffer_code_rows` and
   `DirtyRows` read the root tree or string parsers, and `EdgeConceal`
   runs only for drawn windows. A buffer that no window shows gets
   nothing from the parse. When a window later shows it, the highlighter
   parses the rows on view, as for rows scrolled to for the first time.

`FenceRows:sync` and `buffer_code_rows` stay when no window shows the
buffer: their results go into the text (prose wrap) and into region
rails (`last_drawn_row`), and after cause 1 they cost O(edit).

## Changes
`lua/agentic/ui/fence_rows.lua`, `FenceRows:sync`:
- `first = math.min(first, (block:start()))`.

`lua/agentic/ui/message_writer.lua`, `materialize_injections`:
- Return before the parse when `vim.fn.win_findbuf(bufnr)` is empty.
- Docstring: rewrite the "Called after every content `set_lines`"
  paragraph, which is already false: it is called for each tool call
  block paint, and not for a buffer that no window shows.

`lua/agentic/ui/folds.lua`: delete the sentence saying
`materialize_injections` creates the injected trees on every content
write. Folds read the root tree only, which the docstring already says.

## Tests
- `fence_rows.test.lua`: a buffer with a fence at the top and a second
  fenced block lower down. Clear `FenceRows.NS` by hand (no
  `invalidate`), then edit a row inside the second block, below its
  opener, and `sync`. The second block's opener row is marked again (the
  widening reaches the block's start). The top fence's rows stay unmarked
  (the widening stops there).
- `message_writer.test.lua`, following `test_chat_injections.lua`'s
  `is_valid` pattern, with no redraw between the write and the check:
  - A tool call block written to a buffer that no window shows leaves
    the parser not valid for the block's range
    (`not parser:is_valid(false, { range })`).
  - The same write with the buffer in a window leaves it valid for the
    block's range.

## Expected outcome
- A tool call in a hidden 33k-line transcript costs about 6 ms (measured
  with both changes applied to copies of the files).
- Skeptics and hidden subagent transcripts do not slow typing.
- The skip applies to every chat buffer that no window shows, the main
  chat included.
- An edit inside a fenced block re-marks fence rows only in that block
  and its dirty span, in every chat buffer, shown or not.

## Non-goals
- The range parse in a buffer on view: about 100 ms per tool call block
  at 33k lines. Its cause in core (an injection pass that costs O(buffer)
  for any range) is not known. No shown buffer that large has been seen.
- Forcing a parse when a window first shows a hidden buffer. The
  forced parse exists for a block written into a shown window, where an
  async parse was seen not to complete; that has not been seen on a newly
  shown window.
- Bounding the skeptic transcript's length.
- The `timeout`s of the skeptic: they may have come partly from the
  blocked loop. Check again after this lands.
