# Plan: hide chat fence rows with extmarks, not treesitter `conceal_lines`
Status: spec

## Relevant files

- `lua/agentic/ui/chat_buffer.lua` — `start`, `defer_conceal`, `conceallevel`
- `ftplugin/AgenticChat.lua` (trackpad-scroll comment); the user's
  `~/dotfiles/config/nvim/plugin/treesitter.lua` (FileType `vim.treesitter.start`)
- `queries/agentic/highlights.scm` (comment), `queries/agentic/folds.scm` (comment)
- `lua/agentic/ui/message_writer.lua` — `new`, `_own_edit`, `reset`, `on_window_split`, `on_row_heights_changed`, BufWinEnter autocmd
- `lua/agentic/ui/folds.lua` — dirty-row tracking (`mark_dirty`, `splice`, `watch`, `state_of`, `refresh`) moves to a shared utility
- `lua/agentic/ui/tool_call_layout.lua` — `FOLD_THROUGH_MARKERS`, the fold-suffix encoder
- `lua/agentic/ui/agent_view.lua` (`restart`), `lua/agentic/session_manager.lua` (`_reload_chat`, `clear_chat`), `lua/agentic/ui/subagent_transcript.lua` (`restart`), `lua/agentic/ui/chat_widget.lua` (`clear`) — writes and mark clears outside `_own_edit`
- `lua/agentic/utils/after_draw.lua` (+ test) — only user is `defer_conceal`
- `lua/agentic/utils/treesitter.lua`, `lua/agentic/utils/text_wrap.lua` (`is_fence_delimiter` comment)
- `tests/integration/test_first_draw_conceal.lua`, `tests/integration/test_chat_injections.lua`, `lua/agentic/ui/chat_buffer.test.lua`, `lua/agentic/ui/folds.test.lua`
- `.claude/rules/session-isolation.md` (names `AfterDraw`'s registry), `.claude/skills/rendering/SKILL.md`
- nvim runtime: `lua/vim/treesitter.lua` (`start`), `lua/vim/treesitter/highlighter.lua` (`new` `opts.queries`, `get_query`, `_on_conceal_line`, `on_bytes`, `set_conceal_lines`, `on_range_impl`), `lua/vim/treesitter/languagetree.lua` (`_parse`, `_get_injections`, `_add_injections`, `resolve_lang`), `lua/vim/treesitter/query.lua` (`get_files`, `has_conceal_line`)
- Skills: `rendering`, `follow`, `lua-class`; neovim `references/rendering.md` § Parse cost at `conceallevel >= 2`

## Background

Live chats stall at 'conceallevel' 2 (`'redrawtime' exceeded, syntax
highlighting disabled`). The message comes from regex syntax (`syntax/AgenticChat.vim`),
but its time limit covers the whole window redraw (`drawscreen.c`
`win_update`), so it only says that one redraw took more than 2 s.
Disabling syntax removes nothing that costs time.

Cause:

1. Core. If any highlights query of the buffer's trees has `conceal_lines`,
   the highlighter gets the height of each unchecked row from
   `_on_conceal_line`, which runs `parse({row, row + 1})`. `on_bytes` forgets
   all checked rows on every edit. When the row is outside
   `_processed_injection_region` (a reparse after an edit resets it),
   injections are recomputed for that row alone, and `_add_injections` drops
   every child language not in the row and narrows the others to it. Each
   row then costs an injection query and a child-tree destroy and rebuild,
   and the next redraw rebuilds the visible children again.
2. Plugin. Follow measures rows after every write, and each measurement takes
   the path above. Row parses in 50 streamed chunks, by caller:
   `BufHelpers.fitting_topline` → `screen_rows` ~18k, `view_of` in
   `MessageWriter:_own_change` ~12.5k, the redraw itself ~2.4k. Measurements
   also run outside a write: in `_schedule_follow`'s scheduled callback, in
   `on_view_change` (WinScrolled, CursorMoved) through `view_of`, and in
   `BufHelpers.show_rows`, whose binary search starts at line 1.

A field sample of a frozen chat (main thread at 100%, 2598 samples over 3 s)
showed this path in every sample: a scheduled callback in normal mode →
`nvim_win_text_height` → `decor_providers_invoke_conceal_line` → Lua →
`ts_query_cursor_next_match` (≈99%). Whether that freeze would have ended is
unknown.

The only `conceal_lines` source is markdown's highlights query (fence
delimiter and info-string rows). It reaches the chat as the root query
(`queries/agentic/highlights.scm` is `; inherits markdown`) and through every
child tree whose language is `markdown`. Children come from the chat's own
fences (`markdown`, `pandoc`, any case) and from injections of other
languages: a zsh heredoc into a `.md` file (the user's `#inject-by-ext!`), a
Julia docstring. The highlighter's flag is sticky: one such child turns the
path on until the highlighter is destroyed.

Measured with the real config in a 260×75 pty after a replay. The extmark
column hides the same rows with `conceal_lines` extmarks while the
highlighter's `conceal_lines` path is off:

| | treesitter, level 2 | extmark, level 2 | level 0 |
| --- | --- | --- | --- |
| stream, chat A (2.7k lines) | 46 ms/chunk | 4.9 | 3.1 |
| stream, chat B (3.9k lines) | 12 ms/chunk | 8.6 | 4.9 |
| `<C-u>`, chat A | 35 ms | 1.3 | 2.9 |
| replay, chat A | 2234 ms (22.5k parses) | not measured | 497 ms (1.2k) |
| new window's first draw, 18.9k lines | 726 ms | 57–106 | 74 |

Hiding the rows with extmarks removes the row-parse path at its source: no
query the chat's highlighter uses has `conceal_lines`, so `_on_conceal_line`
returns at once and a row's height is an extmark lookup. The writer's follow
math and nvim's own scrolling become cheap together, and
`ChatBuffer.defer_conceal`, which works around the same cost at a
window's first draw, has nothing left to work around. Capping the plugin's
measurements instead would leave native scrolling at 31–35 ms per `<C-u>`.

The stripped queries are given to the chat's highlighter only
(`highlighter.new(parser, { queries = … })`, which `get_query` reads before
any query file), for `agentic` and for `markdown`. That covers every route a
markdown child can take, and leaves real markdown buffers and the global
queries alone. Children keep their language, so markdown bodies keep their
`.markdown` highlight groups, textobjects and context queries.
`vim.treesitter.start` is only `get_parser` plus `highlighter.new(parser)`,
so `ChatBuffer.start` calls the two itself. `highlighter.new` returns the
active highlighter unchanged, `opts` ignored, when one exists for the same
parser, and the user's FileType autocmd (`plugin/treesitter.lua`,
`vim.treesitter.start(buf)`) makes one with the file queries when the
filetype is set, before `ChatBuffer.setup`. So `ChatBuffer.start` destroys
the active highlighter first.

Which rows are fence delimiters is read from the root tree, never from line
shape (`TextWrap.is_fence_delimiter` cannot see a ```` ``` ```` line inside a
four-backtick fence). The root tree is parsed without injections
(`parser:parse()`): it skips `_get_injections` and destroys no child.

## Changes

### `lua/agentic/utils/treesitter.lua`

- `Treesitter.strip_conceal_lines(text: string): string` — `text` with every
  `#set!` predicate whose first non-capture parameter is `conceal_lines`
  removed, found by parsing `text` with the bundled `query` parser, not by
  pattern matching. The capture form `(#set! @c conceal_lines "")` counts:
  core does not set `has_conceal_line` for it, but `on_range_impl` still
  places marks from `metadata[capture].conceal_lines`.
- `Treesitter.resolve_lang(alias: string): string|nil` — the language core
  injects for `alias`, in `resolve_lang`'s order: whitespace removed,
  lowercased, `-` to `_`; nil unless `[%w_]+`; the name itself when a parser
  of that name exists, else `vim.treesitter.language.get_lang` of it when that
  parser exists.

### `lua/agentic/ui/tool_call_layout.lua`

- `ToolCallLayout.base_lang(word: string): string` — `word` without the
  `-fold`, `-foldnext` or `-foldfence` suffix, beside the encoder
  (`FOLD_THROUGH_MARKERS`).

### `lua/agentic/ui/chat_buffer.lua`

- local `highlight_queries(): table<string, string>` — built once: the files
  of `vim.treesitter.query.get_files("markdown", "highlights")` read in order,
  joined with `"\n"` (core's `read_query_files` joins with `""`, which glues a
  file's unterminated last line to the next file's first), passed through
  `Treesitter.strip_conceal_lines`, as the value for both `agentic` and
  `markdown`. `query.parse` reads no modelines, so none need guarding.
- `start`: in place of `vim.treesitter.start(bufnr, "agentic")`,
  `vim.treesitter.stop(bufnr)` and then
  `vim.treesitter.highlighter.new(vim.treesitter.get_parser(bufnr, "agentic"),
  { queries = highlight_queries() })`, with the same markdown fallback. The
  stop is needed: the user's FileType autocmd has already made a highlighter
  on the same parser, and `highlighter.new` returns that one as it is. A later
  same-language `vim.treesitter.start` (FileType again) is then a no-op that
  keeps this highlighter. `:e` re-runs `start` through `_reload_chat`.
- Delete `defer_conceal` and the `AfterDraw` require.
- `conceallevel`: drop the `vim.w[winid].agentic_conceallevel` read and that
  sentence of its docstring.

### New `lua/agentic/utils/dirty_rows.lua`

`agentic.utils.DirtyRows` — the rows of a buffer that an edit or a root-tree
change touched since the last `take`. What moves out of `folds.lua`:
`mark_dirty`, the dirty-span half of `splice`/`moved`, `watch`, and the parser
check and `parser:parse()` in `refresh`. What stays there: the `levels` and
`skip` splice, `fit`, the `on_reload` skip reset and the state drop on detach,
so `folds.lua` keeps its own `nvim_buf_attach`.

- `DirtyRows.watch(bufnr: integer): agentic.utils.DirtyRows` — attaches
  `on_bytes` (the edit's new rows, its end row included, become dirty; as
  `folds.lua`'s `splice` moves them, recorded rows below the edit shift by its
  line delta, recorded rows inside the replaced ones move to its first row,
  and the span is clamped to the line count), `on_reload` (all dirty) and
  `on_detach` (all dirty, and no longer attached), and the root parser's
  `on_changedtree`, guarded so a replaced parser's callbacks do nothing
  (callbacks cannot be unregistered).
- `DirtyRows:take(): [integer, integer][]|nil` — nil when clean, without
  looking up the parser (`folds.lua` calls it from `foldexpr`, once per line).
  When dirty: attaches again if detached (`:e` and `:bunload` unload the
  buffer; only FenceRows reaches this, as folds rebuilds its state after a
  detach) or registers on a replaced parser, and then returns the whole
  buffer; else parses the root (`parser:parse()`, whose `on_changedtree` can
  add rows) and returns the dirty rows as disjoint 0-indexed inclusive spans,
  joined where they meet (`Intervals.union`), so two edits far apart do not
  dirty everything between them. Then clean. Nil when the buffer has no
  parser.
- `DirtyRows:mark_all()` — the whole buffer is dirty.
- `folds.lua` reads its dirty rows from a `DirtyRows`, dropping its own root
  parse before reading them; `folds.test.lua` keeps passing unchanged.

### New `lua/agentic/ui/fence_rows.lua`

`agentic.ui.FenceRows` — a `conceal_lines = ""` extmark on every fence
delimiter row of one chat-style buffer. Held by its `MessageWriter`, so no
module-level registry. Its module docstring is the one place that says why the
chat's queries carry no `conceal_lines`; other comments point here.

- `FenceRows.NS: integer`
- `FenceRows:new(bufnr: integer): agentic.ui.FenceRows` — watches the buffer
  with `DirtyRows` and marks it all dirty.
- `FenceRows:sync()` — no-op when the buffer is invalid or `take` returns nil.
  Else, per span: widen it to every whole `fenced_code_block` it meets, delete
  this namespace's marks on it, and set a mark on each row `delimiter_rows`
  returns for it. The widening is needed because an edit inside a block can
  change which of its body rows are nested delimiters outside the edit (a
  deleted nested closer turns the ```` ```lang ```` rows after it into
  content; an opener's language changed away from markdown leaves its old
  nested marks), and the root tree sees only `code_fence_content` there and
  reports no change. Only markdown blocks are string-parsed; for the rest the
  widening costs a namespace clear and the root query over the block.
- `FenceRows:invalidate()` — `mark_all`, for a caller that cleared the
  namespace.
- local `delimiter_rows(root: TSNode, source: integer|string, first: integer, last: integer): integer[]`
  — 0-indexed rows of `fenced_code_block_delimiter` nodes in rows
  `first`..`last`. For each `fenced_code_block` in the span whose language
  (`Treesitter.resolve_lang(ToolCallLayout.base_lang(word))`) is `markdown`,
  also the delimiter rows of its `code_fence_content`, parsed with a
  `vim.treesitter.get_string_parser(content, "markdown")` and offset by the
  content's start row, recursively. A string parse is not incremental, so an
  update of a markdown body costs O(body). The writer already rewrites a tool
  call body whole on each update (`update_tool_call_block`), so this adds no
  worse order of cost; agent prose lives in the root tree and is never
  string-parsed.
- The query `(fenced_code_block_delimiter) @d` is parsed once, as a local.

### `lua/agentic/ui/message_writer.lua`

- `new`: `self._fence_rows = FenceRows:new(bufnr)`.
- `_own_edit`: inside the `_own_change` closure, after `with_modifiable`, call
  `self._fence_rows:sync()`, so marks are right before `view_of` and the
  follow math measure rows.
- `reset`: after it clears every namespace, `self._fence_rows:invalidate()`.
  The text stays (`AgentView:restart`), and the next `_own_edit` stamps it.
- BufWinEnter autocmd: drop the `defer_conceal` call.
- `on_window_split`: replace the `defer_conceal` call with the body of
  `on_row_heights_changed` (user control: `_own_change(function() end)`;
  following: `_follow_from_top`), and keep the mode copy. A split fires only
  WinNew, so this is its only placement. It now runs at every level, not only
  at level 2 where `defer_conceal` ran it: `:split` halves the window, so a
  following split at level 0 or 1 also needs placing at the end.
- `on_row_heights_changed`: delete.

Writes outside `_own_edit` need no change. `ChatWidget:clear` is called only
from `SessionManager:clear_chat`, which runs `message_writer:reset()` right
after it. `SubagentTranscript:restart` runs `view:restart()` (a reset) before
its `set_lines`. Either way the reset clears every mark, collapsed ones
included, and `invalidate` makes the next `_own_edit` stamp the new text.

### `lua/agentic/utils/after_draw.lua`, `after_draw.test.lua`

- Delete (no other user).

### Comments and docs

- `queries/agentic/highlights.scm`: its comment says the conceal_lines
  metadata is kept for a trackpad-scroll workaround; say instead that the
  chat's highlighter gets this query without `conceal_lines` (see
  `FenceRows`).
- `queries/agentic/folds.scm`, `TextWrap.is_fence_delimiter`, and the
  trackpad-scroll comment at the top of `ftplugin/AgenticChat.lua` ("treesitter's
  conceal_lines makes … zero-height"): the zero-height fence rows come from
  `FenceRows` (pointer, not a restatement).
- `Treesitter.highlight_trees` docstring: it reads the file queries
  (`query.get`), not the highlighter's, so drop "with its highlights query".
  Its one user, `EdgeConceal`, reads only `conceal`, which both have.
- `.claude/rules/session-isolation.md`: drop the `AfterDraw` registry
  exception.
- `rendering` skill, buffer-wide rules: one line — fence delimiter rows are
  hidden by `FenceRows` extmarks (see its module docstring).

### Tests

- `dirty_rows.test.lua`: an edit marks its rows; a later edit above shifts
  them; a root-tree change far from the edit widens the span; a new parser
  returns the whole buffer; after `:bunload` and a reload, an edit is seen
  again and the first `take` returns the whole buffer; a clean `take` does
  not call `get_parser`.
- `fence_rows.test.lua`:
  - exactly the delimiter rows of prose with two fences are marked;
  - an opener written before its closer, then the closer: rows between
    unmarked, closer marked;
  - several edits at different rows in one `_own_edit`;
  - deleting a fenced block leaves no mark on the rows that replace it;
  - a ```` ``` ```` line inside a four-backtick fence is not marked;
  - delimiters inside a ```` ```markdown-fold ```` body are marked; deleting a
    nested closer in that body unmarks the ```` ```lang ```` rows after it
    and sets no duplicate mark;
  - after `MessageWriter:reset` with the text kept, the next write restores
    every mark.
- `treesitter.test.lua`: `strip_conceal_lines` removes only `conceal_lines`
  predicates, in both forms; the stripped markdown query parses with
  `has_conceal_line == false`. `resolve_lang`: `Markdown` → `markdown`;
  `pandoc` → `markdown` after `language.register("markdown", "pandoc")`, else
  nil; `md` → nil; `zsh` → `zsh`; `""` → nil.
- `tool_call_layout.test.lua`: `base_lang` for each fold marker and for a
  word without one.
- Integration (`test_chat_injections.lua`): `tests/init.lua` strips the
  user's config from 'runtimepath', so the child first gets a FileType
  autocmd that calls `vim.treesitter.start(buf)` (as `plugin/treesitter.lua`
  does) and a zsh injections query (`vim.treesitter.query.set`) that injects
  `markdown` into a heredoc body (the user's `#inject-by-ext!` is not loaded),
  and `pandoc` is registered to `markdown`. Then, after `:Agentic` and writing
  a tool call with a `markdown-fold` body, a ```` ```pandoc ```` and a
  ```` ```Markdown ```` body, a lua fence, and an execute command with a
  heredoc, `vim.treesitter.highlighter.active[chat]._conceal_line` is falsy
  and the zsh tree has a `markdown` child; a `##`
  heading in the `markdown-fold` body has `@markup.heading.2.markdown`; at
  level 0 `nvim_win_text_height` counts the fence rows; after `:e` of the chat
  the marks are back and `_conceal_line` is still falsy.
- Integration, same file, guarding the user-visible symptom: with the chat at
  level 2 in a following window, wrap `LanguageTree.parse` and count root
  `parse({row, row + 1})` calls. Zero over each of: 20 streamed chunks with
  the scheduled follow drained (`tests/helpers/deferred.lua`); a `<C-u>`
  afterwards (WinScrolled → `on_view_change`); a `BufHelpers.show_rows` of a
  block near the end. Also 20 streamed updates of one 500-row
  `markdown-fold` body take at most twice as long as the same updates of a
  `console` body.
- `test_first_draw_conceal.lua`: keep the placement cases (a split fills to
  the end, a window that newly shows the chat fills to the end, follow off
  ends on the last line, a held block is placed, the user-control cases);
  drop what only checks the level-0 draw and restore. "keeps its topline"
  compares the new window's topline with its source window's, and drops the
  `on_row_heights_changed` wrapper (`:154`). Add: a `:split` of a following
  window at level 0 fills it to the end. Rename to match.
- `chat_buffer.test.lua`: delete the `defer_conceal` cases. Add: on a buffer
  where `vim.treesitter.start(buf)` already runs, `ChatBuffer.start` leaves
  an active highlighter with `_conceal_line` falsy; a `vim.treesitter.start(buf)`
  after it keeps that highlighter.

## Expected outcome

- At level 2, streaming, scrolling and replay cost about what they cost at
  level 0 (table above).
- A new chat window draws at its own level from its first draw.
- Fence rows of the chat's own fences, nested ones in markdown bodies
  included, stay zero-height. At levels 1 and 0 they show as before
  (`conceal` metadata is kept).
- Fence rows in markdown that another language injects (a heredoc into a
  `.md` file, a Julia docstring) are no longer zero-height. Their delimiter
  text is still concealed at level 2, so each shows as an empty row. Accepted:
  that markdown is the content of a code block (a file a command writes, a
  docstring), where rows show as written; hiding them again would need marks
  read from child trees, which come and go with the parsed range.
- A following split at level 0 or 1 is placed at the end, as at level 2.

## Non-goals

- The markdown fallback when the `agentic` language cannot be registered.
  That happens only when `markdown.so` is missing or fails to load, and then
  `markdown` cannot start either, so no highlighter runs this path.
- Real markdown buffers, the input buffer, and the global queries: untouched.
- Markdown highlight extensions added after the first chat starts (a later
  `packadd`), and a `vim.treesitter.query.set("markdown", "highlights", …)`
  override, which `get_files` does not see: the stripped query is built once
  from the files and ignores both.
- A highlighter made later by other code for the chat buffer in another
  language (`vim.treesitter.start(chat, "markdown")`): it replaces the parser
  too, uses the files' queries and turns the path back on until the next
  `ChatBuffer.start`. A same-language `vim.treesitter.start` is a no-op.
- The remaining ~0.5 s of a level-0 replay of a 2.7k-line session.

## Open questions

None.
