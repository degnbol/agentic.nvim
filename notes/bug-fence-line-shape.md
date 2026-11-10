# Bug: fence rows recognised by line shape, not by the parse tree

Several sites decide whether a chat row is a fence delimiter by its text
(`^```, `^`+$`, `TextWrap.is_fence_delimiter`). A line's shape does not decide
that: markdown matches a closer to its opener (same character, no info
string, at least as long), and only the opener's run tells which ```` ``` ````
lines inside it are content. The writer makes such content on purpose:
`TextWrap.safe_fence` opens a fence one backtick longer than any run in the
body, so every body that holds a code block has ```` ``` ```` rows that are
content.

The chat's zero-height rows come from the tree: `agentic.ui.fence_rows` marks
the `fenced_code_block_delimiter` rows of the root tree and of markdown
bodies. A line-shape test disagrees with it in these cases:

| Row | Shape test says | Tree / `FenceRows` says |
| --- | --- | --- |
| ```` ``` ```` inside a ```` ```` ```` fence of a non-markdown language | delimiter | content, drawn |
| ```` ``` ```` in markdown that another language injects (a heredoc, a docstring) | delimiter | content of the host, drawn |
| `~~~` fence | not a delimiter (for `^```) | delimiter, zero-height |
| fence indented 1–3 spaces, or inside `>` / a list item | not a delimiter (for `^```) | delimiter, zero-height |
| ```` ```lua ```` after a deleted nested closer, in a markdown body | delimiter | content (the earlier block is unclosed) |
| any delimiter at 'conceallevel' 0 or 1 | zero-height (where the site assumes so) | drawn |

## Sites

### 1. Trackpad scroll workaround — `ftplugin/AgenticChat.lua` `skip_concealed_line`

Moves the cursor off "zero-height" rows before and after each
`<ScrollWheel*>`, found by `getline(l):match("^```")`. Introduced in
`22e4cf7` for the cursor-stuck-on-a-concealed-row symptom.

- A drawn ```` ``` ```` content row (first table row) is skipped: the cursor
  jumps past a visible row on a wheel scroll.
- A zero-height `~~~` or indented delimiter is not skipped: the stuck-cursor
  symptom the workaround exists for still occurs on those rows.
- The level gate (`conceallevel < 2`) is right for the chat's marks. It is not
  a height test, so a closed fold or another `conceal_lines` source is not
  covered either.

Candidate tests for "this row has no height": a mark in `FenceRows.NS` on the
row, or `nvim_win_text_height(0, { start_row = r, end_row = r }).all == 0`.
The second covers every source of zero height.

### 2. Region corner placement — `message_writer.lua` `last_drawn_row`

Walks up from a region's last row past blank rows and
`TextWrap.is_fence_delimiter` rows, so the `╰─` sign lands on a drawn row. Its
docstring says a fence delimiter is zero-height (`agentic.ui.FenceRows`).
Called from `render_region_rail`, `render_prose_region`,
`render_collapsed_region` and `_extend_prose_region`.

- A region ending in a ```` ```` ```` block whose last body row is
  ```` ``` ````: the walk skips the closer (right), then the drawn
  ```` ``` ```` row too, and puts the corner above it.
- At 'conceallevel' 0 or 1 every delimiter is drawn, and the corner still
  skips it.
- Markdown injected by another language: since `fd4bb21` its delimiter rows
  are drawn, but this helper still skips them. It only matters when such a
  row ends a region.

### 3. Prose reflow — `TextWrap.wrap_prose` (and `wrap_single_line`)

Toggles `in_fence` on every `^%s*```` line. Measured with
`wrap_prose({"````markdown", "```", "inside <long>", "```", "still inside <long>", "````", "after <long>"}, 40)`:

- `inside …`, content of the four-backtick block, is re-wrapped to 40
  columns. Code inside a longer fence is reflowed when the agent writes a
  fence inside a fence.
- `still inside …` and `after …` come out right only because the toggles
  pair up again. An odd count of inner ```` ``` ```` rows leaves the rest of
  the message in the wrong state: prose after the block is left unwrapped,
  or code after it is wrapped.
- `~~~` fences do not toggle, so their content is reflowed.

`TextWrap.unclosed_fence`'s docstring already notes that it follows the
markdown rule, unlike `wrap_prose`'s toggle. `wrap_single_line` exempts any
`^%s*```` line from wrapping, which is harmless on its own.

### 4. Permission-prompt command span — `permission_highlight.lua` `OPEN_FENCE` / `CLOSE_FENCE`

Finds the command between the first `^`+%a*$` row and the next `^`+$` row of
the block. A command holding a ```` ``` ```` line (a heredoc that writes
markdown) gets a ```` ```` ```` command fence from `safe_fence`, and the scan
ends at the inner ```` ``` ````. The unapproved-range wash then covers only
part of the command. The module says it is pure UI and fails safe (the prompt
still fires), so this hides a warning, never grants.

`OPEN_FENCE` also rejects any language with a `-`, which is fine only while
the command fence keeps its bare language until output exists (comment in
`ToolCallLayout.assemble`).

## Not affected

- `TextWrap.unclosed_fence`, `TextWrap.fenced_inner`: implement the markdown
  closer rule over the lines given; the right tool for balancing text.
- `SessionResume.message_title`: asks whether a message's first text line
  opens a fence, a question about the text, not about how the chat draws it.
- `Folds.foldtext` (`row:match("^`+")`): a backtick code span at the start of
  a row, not a fence.
- `FenceRows` itself and `queries/agentic/folds.scm`: read the tree.

## What to check

- Whether sites 1 and 2 should ask for height (`nvim_win_text_height`, or a
  `FenceRows.NS` mark) instead of shape; that also makes them follow
  'conceallevel' and folds without a separate gate.
- Whether site 3 can reuse `unclosed_fence`'s closer rule as a running state
  (opener run and character kept, a closer matched against it), so nested
  fences and `~~~` are handled in one place.
- Whether site 4 can take the command's rows from the layout that wrote them
  (`ToolCallLayout` knows the fence rows of each section) instead of
  re-scanning the buffer text.
- Tests: a four-backtick block with an inner ```` ``` ```` row, a `~~~` fence
  and an indented fence for each site.
