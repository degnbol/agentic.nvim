# Plan: nested command and output folds for execute and search blocks
Status: reviewed spec

## Relevant files

- `queries/agentic/folds.scm`, `queries/agentic/injections.scm`
- `lua/agentic/ui/folds.lua` — `levels`, `foldtext`
- `lua/agentic/ui/tool_call_layout.lua` — `Section`, `Layout`, `assemble`,
  `output_section`, `reason_section`, `execute_fold_state`, `HEADS.execute`,
  `HEADS.search`, `BODIES.execute`, `BODIES.search`, `M.build`
- `lua/agentic/ui/message_writer.lua` — `ToolCallBlock` fold fields,
  `_drop_block_fold`, `_sync_block_fold`, `_render_block_fold`,
  `_settle_block_fold`, `_write_status_and_settle_fold`, `apply_fold`,
  `replay_folds`, `flush_pending_fold_ops`, `hold_tool_call`,
  `update_tool_call_block`
- `lua/agentic/utils/buf_helpers.lua` — `recompute_folds` (neighbour of the
  new `set_fold`)
- `lua/agentic/ui/permission_highlight.lua` — `OPEN_FENCE` (read only; see
  the `-join` condition)
- `lua/agentic/config_default.lua` — `tool_call_display` docs
- `doc/agentic.txt` — `*agentic-config-tool_call_display*`
- Skills: `rendering` (§ Fence info-strings, § Body folding, § Adding a new
  foldable kind), `neovim` → `references/folding.md`
- `notes/PLAN-incremental-fold-levels.md` — assumes flat level-1 folds

## Background

Since `63a8006`, an execute block has one fold over its command and output.
The fold closes when the command is read-only and did not fail, or when the
output passes `execute_max_lines`. The second rule hides a command that can
write, only because its output is long. Length is a reason to hide output,
never a command.

Search blocks (Grep/Glob) show their `rg` command in a `bash` fence that never
folds, and fold the output alone past `search_max_lines`. A search is
read-only by kind, so it is the same case as a read-only execute command.

Every execute and search block with output gets the same two folds, and two
independent rules give their start states. The user can then `zc`/`zo` either
fold on any block, also when the rules leave it open.

| Fold | Spans | Closed at render when |
|---|---|---|
| Outer | command rows through output rows | the call did not fail and is safe: execute → `PermissionRules.is_read_only`, search → always |
| Inner | output rows | output rows > `<kind>_max_lines` (0 = never) |

A successful search closes at any length, as a read-only execute does today;
the fold text shows the `rg` command.

### nvim behaviour on nested folds

`setManualFoldWin` (`src/nvim/fold.c:1177`, v0.12.6) opens the topmost
closed fold at the row, and closes the deepest open fold above the first
closed one (nothing when the top fold is closed). Measured with
`nvim --clean`, expr folds, outer fold rows 1–8, inner fold rows 3–8:

- `3foldclose` closes the inner fold. A second `3foldclose` closes the outer
  fold.
- With the outer closed, `3foldopen` opens the outer fold, not the inner one.
- With the outer closed, `3foldclose` changes nothing; the inner fold is still
  open after `1foldopen`.

So one `:foldopen`/`:foldclose` on the anchor row (today's `apply_fold`) is not
idempotent on nested folds. `replay_folds` re-applies every state, and a user
`zc` before a settle makes a repeated close escalate to the outer fold. The
fold op must target the fold that starts at the anchor row.

## Changes

### `queries/agentic/folds.scm`

- The join pattern keys on a `-join` marker on the first fence, and accepts
  `console` or `console-fold` as the second:
  `(#lua-match? @_lang "%-join$")`,
  `(#any-of? @_output "console" "console-fold")`. `-join` does not match
  `fold$`, so the command fence forms no fold of its own.
- Top comment: folds nest by containment (outer join, inner `-fold`). Keep the
  ban on `; inherits: markdown` because its section folds would fold prose.

### `queries/agentic/injections.scm`

- Strip `-join` the same way as `-fold`, so `zsh-join`/`bash-join` fences
  still inject.

### `lua/agentic/ui/folds.lua`

- New pure function, tested without treesitter:
  ```lua
  --- Foldexpr value per line for fold ranges that are disjoint or nested:
  --- each line's depth is the number of ranges covering it, with `">" ..
  --- depth` on the first line of each range.
  --- @param ranges [integer, integer][] 1-indexed first and last line
  --- @param line_count integer
  --- @return string[] levels
  local function levels_of_ranges(ranges, line_count)
  ```
- `M.levels(bufnr)` collects each match's `[first, last]` and returns
  `levels_of_ranges(...)` with `joined`. It keeps the `last > first` guard
  ('foldminlines' = 1). A match with an `@fold.end` capture whose second fence
  does not open on the next row forms no fold, so a `-join` command with no
  adjacent output is never hidden. Update the docstring and the "Every fold is
  level 1" comment.
- `foldtext`: no change. `joined[first]` marks the outer fold, and the inner
  fold has no name word, so it reads `N lines`.

### `lua/agentic/ui/tool_call_layout.lua`

- `Section`: add `--- @field join? boolean`: with `fold`, the marker is
  `-join` and the fold runs through the next section's fence. Without `fold`
  it has no effect, so a command fence has no marker until output exists
  (`permission_highlight.lua`'s `OPEN_FENCE` matches only `^`+%a*$`).
  `assemble`: `fold and join` → `-join`, else `-difffold`/`-fold` as now.
- `Layout`: replace `fold?` with
  `--- @field folds agentic.ui.ToolCallLayout.Fold[]`, outermost first, where
  `--- @class agentic.ui.ToolCallLayout.Fold` has `anchor: integer` and
  `state: agentic.ui.FoldState`. `assemble` appends one entry per section with
  `fold` and drops the "at most one fold" error.
- New:
  ```lua
  --- Start state of a fold over output rows: nil for one row or none (no fold
  --- forms, and an anchor there would act on the outer fold), closed past
  --- `max_lines` (0 = never), else open.
  --- @param rows string[]
  --- @param max_lines integer
  --- @return agentic.ui.FoldState|nil
  local function output_fold_state(rows, max_lines)
  ```
- Replace `execute_fold_state(call)` with:
  ```lua
  --- Start state of the fold over a command and its output: nil without
  --- output rows, closed when the call did not fail and is safe, else open.
  --- @param output string[]
  --- @param failed boolean
  --- @param safe boolean
  --- @return agentic.ui.FoldState|nil
  local function command_fold_state(output, failed, safe)
  ```
  Callers pass `call.failure or call.block.body or {}` and
  `call.block.status == "failed"`.
- `output_section(rows, max_lines)`: `fold = output_fold_state(rows, max_lines)`.
  Only search and execute use it.
- `HEADS.execute`: `join = true`,
  `fold = command_fold_state(..., PermissionRules.is_read_only(call.argument))`.
- `BODIES.execute`: `output_section(rows, Config.tool_call_display.execute_max_lines)`.
- `HEADS.search`: `join = true`, `fold = command_fold_state(..., true)`.
- `M.build`, failure branch: for `search`, the `reason_section` also gets
  `fold = output_fold_state(call.failure, search_max_lines)`.

### `lua/agentic/utils/buf_helpers.lua`

- New:
  ```lua
  --- Give the fold that starts at `lnum` in `winid` the state `open`,
  --- leaving every other fold's state as it was.
  --- @param winid integer
  --- @param lnum integer 1-indexed first line of the fold
  --- @param open boolean
  --- @return string|nil err E490 when no fold starts at `lnum`, or the error of a fold command
  function BufHelpers.set_fold(winid, lnum, open)
  ```
  In `winid` (`nvim_win_call`):
  0. Return an E490 error unless `foldlevel(lnum) > foldlevel(lnum - 1)`.
     This proves a fold starts at `lnum` only when `lnum - 1` lies outside
     that fold; it misses a fold that starts right after a same-level sibling.
     State that precondition in the docstring. Every chat anchor follows its
     fence row, which is outside its fold, so it holds here.
  1. While `foldclosed(lnum)` is neither -1 nor `lnum`: `:foldopen` at that
     start and push it.
  2. `open` and `foldclosed(lnum) == lnum` → `:foldopen` at `lnum`;
     not `open` and `foldclosed(lnum) == -1` → `:foldclose` at `lnum`.
  3. `:foldclose` each pushed start, last pushed first.
  Steps 1 and 3 rely on no two folds starting on the same line. Step 2
  relies on no fold being small enough for 'foldminlines' to show it open
  (`foldclosed()` returns -1 for it, so a second close hits the parent): the
  chat pins 'foldminlines' = 1 and `Folds.levels` forms no one-line fold.
  Algorithm and preconditions: neovim skill `references/folding.md` § Nested
  folds.

### `lua/agentic/ui/message_writer.lua`

- Remove `apply_fold`; `replay_folds` and `flush_pending_fold_ops` call
  `BufHelpers.set_fold(winid, pos[1] + 1, open)`.
- `ToolCallBlock`: replace `fold_anchor_id`, `fold_open`, `fold_sent` with
  `--- @field folds? agentic.ui.MessageWriter.BlockFold[]`, outermost first,
  where `--- @class agentic.ui.MessageWriter.BlockFold` has
  `anchor_id: integer`, `open: boolean`, `sent?: boolean`.
- Generalise to the list:
  - `_drop_block_folds(block)`
  - `_sync_block_folds(block)`: each fold wants `open`, or for index 1 also
    a hold that reveals this block. The hold reveals the outer fold only.
  - `_render_block_folds(block, start_row, folds: agentic.ui.ToolCallLayout.Fold[])`
  - `_settle_block_folds(block, folds: agentic.ui.ToolCallLayout.Fold[])`:
    copies `state == "open"` by index, then syncs.
  - `_write_status_and_settle_folds(block, footer_row, folds: agentic.ui.ToolCallLayout.Fold[]|nil)`:
    on a final status, settles with `folds`, or only syncs when nil.
- `update_tool_call_block`: the diff path passes nil (its states do not
  depend on the status); the unchanged-content path passes `layout.folds`.
- `_queue_fold`'s docstring: the anchor is the first row of its fold at any
  depth; remove "level-1 row".

### Config and help

- `config_default.lua`: the `tool_call_display` comment and the
  `search_max_lines`/`execute_max_lines` fields: the value closes the output
  fold; the command fold closes when the call is safe and did not fail; 0
  never closes the output fold by length (the fold still exists).
- `doc/agentic.txt`: the same for the section intro ("0 disables that fold")
  and both option entries.

### Skills and notes

- `rendering` skill: the info-string table (`<shell>-join`, `bash-join`,
  `console-fold`), § Body folding (the nested pair), and § Adding a new
  foldable kind (`-join` with `fold` before a `console` section joins).
- `notes/PLAN-incremental-fold-levels.md`: its premise "folds are flat, level
  1" no longer holds. A line's level still depends only on the ranges that
  cover it, but a changed inner fold also dirties its enclosing fold.

### Tests

New:

- `folds.test.lua`: `levels_of_ranges` (disjoint, nested, adjacent); a
  `-join` before `console-fold` gives `>1` on the command and `>2` on the
  output; before `console` (one output row) only the outer fold; without an
  adjacent output, or with a blank line between, no fold.
- `tool_call_layout.test.lua`: the state table for execute (read-only ok,
  read-only failed, writing short, writing long) and search (ok, long,
  failed); one output row has no inner fold; no `-join` before output.
- `buf_helpers.test.lua`: `set_fold`
  over all four outer/inner start states × target × wanted state gives the
  wanted state and leaves the other fold unchanged; a second call changes
  nothing; E490 on a line with no fold and on a line inside a fold that is
  not its start, for both open and close.

Rewrite (old one-fold semantics):

- `message_writer.test.lua:4562-4722` (`fold_fence_lines` pattern, short
  non-read-only execute, "closes when the body grows past the threshold",
  "below one the user opened"), `:3118` (`bash-fold`), `:5312`
  (`bash%-fold\nls`), `:3542` (`tracker.fold_open`).
- `folds.test.lua:149-215` (join and no-join cases on `-fold`), `:450-480`
  (joined foldtext fixture `zsh-fold`).
- `tool_call_layout.test.lua:1216-1260`, `:1868-1923`, `:2155`
  (`zsh-fold`/`bash-fold`); `:357`, `:978`, `:1006`, `:1045`, `:1362`,
  `:2198-2218` (`layout.fold` → `layout.folds`).
- `chat_history.test.lua:761`: fixture field rename.

## Expected outcome

- `mkdir -p x && seq 1 40 | tee x/n`: the command shows; the 40 output rows
  are one closed fold. `zc` on the command hides the whole block.
- `git log -40`: the block is one closed fold whose text starts with the
  command; `zo` shows the command and a closed output fold.
- A Grep/Glob block is one closed fold whose text starts with the `rg`
  command; a failed search stays open.
- A short writing command: both folds open; `zc` works on either.
- A replay into a new window, or a status update that does not change the
  layout's states, does not undo the user's `zc`/`zo`.

## Non-goals

- Other kinds (read, fetch, generic, diffs) keep one fold.
- Changing the read-only rules or the `*_max_lines` defaults.
- Keeping a user `zo`/`zc` across a streamed re-render: each body chunk
  re-renders the block and re-queues both states, as it does for one fold
  today.
- The incremental fold-level recompute (its own plan).
