# Plan: close chat folds at render, open only what needs reading
Status: spec

## Relevant files

- `lua/agentic/ui/tool_call_layout.lua` — `FoldState`, `output_section`,
  `generic_body`, `sidecar_body`, `BODIES.execute`, `diff_body`
- `lua/agentic/ui/message_writer.lua` — `_render_block_fold`,
  `_settle_block_fold`, `_write_status_and_settle_fold`, `hold_tool_call`,
  `release_hold`, `ToolCallBlock` fields `fold_open`/`fold_sent`
- `lua/agentic/ui/permission_manager.lua` — the `hold_tool_call` calls in
  the request open path, `_sync_proxy_hold` and the writer re-anchor
- `lua/agentic/utils/permission_rules.lua` — `M.evaluate`, `walk_command`
  (script execution branch), `M.invalidate_cache`
- `lua/agentic/ui/chat_buffer.lua` — `ChatBuffer.win_opts` (read only:
  `foldlevel` stays 99)
- `lua/agentic/config_default.lua`, `doc/agentic.txt` — `search_max_lines`
- Skills: `rendering` (§ Fence info-strings, § Body folding), `follow`
  (§ Write path), `permissions` (§ Shell command parsing), `neovim` →
  `references/folding.md`

## Background

A `closed_when_final` body (long search, execute and generic output, and
fetch/WebSearch bodies) has no fold state until its call reaches a final
status. It renders open, and `_write_status_and_settle_fold` closes it at
the final status. When the body arrives in an update before the final
status, follow scrolls to the end of the open body. Later the final status
closes the fold. The content gets shorter, and `BufHelpers.scroll_down`
never scrolls up, so empty rows stay below the last line.

A close queued in the same write as the body is not a problem:
`_schedule_follow` leaves the scroll to `flush_pending_fold_ops`, which
scrolls after the close. Thought runs, hook records, folded notices and
`closed` bodies already work this way.

Rule: **a body is closed at render unless the layout says it is required
reading.** A state never changes from open to closed later by itself. With
this rule, `closed_when_final` goes away.

`foldlevel` stays 99. A new expr fold copies the open or closed flag of the
fold before it, and only the first fold follows `'foldlevel'`. This was
verified headless with `--clean`:
- At `foldlevel` 0, a fold appended below a fold opened with `:foldopen` is
  born open.
- A fold whose lines `set_lines` replaced keeps its open flag.

So `foldlevel` 0 would not make bodies born closed. The writer must still
queue the state of every fold explicitly. It already does this for each
state that is due at render.

A large created file was open while its permission prompt showed (it was
`closed_when_final`). It is now `closed` at render. The permission hold
opens it, and the release closes it after the user answers.

Read-only output: the permission decider (`decided_by`) is nil when the
provider approved a call itself, and most `rg`/`ls` calls are approved that
way. So the layout classifies an `execute` command on its own, from the
structured `read_only` gates only. Output that only reads folds like
search output, at `search_max_lines`.

Insert mode: no folds are created while the user types, so fold ops wait
until insert mode ends (`_rebuild_folds_after_insert`). The bodies then
close. This close comes late, so it is accepted.

## Changes

### 1. Fold states (`tool_call_layout.lua`)

- `--- @alias agentic.ui.FoldState "open"|"closed"`. Docstring: the state
  is due at render.
- `output_section`, `generic_body`: `"closed"` past the threshold.
- `sidecar_body`: always `"closed"`. Remove the `subagent` branch and its
  comment.
- `diff_body`: `fold = #rows > 1 and (open and "open" or "closed") or nil`.
  Rewrite the comment above `create_max`: a large create and a failed diff
  are closed at render, and a permission hold opens the block
  (`MessageWriter:hold_tool_call`). Keep the sentence about the explicit
  state, and make it general: a new fold copies the flag of the fold
  before it.
- `BODIES.execute`: the threshold is `search_max_lines` when
  `PermissionRules.is_read_only(call.argument)`, else `execute_max_lines`.
  This applies to failed output too.

### 2. One fold sync per block (`message_writer.lua`)

- New field: `--- @field _revealed_tool_call_id? string The tool call whose
  fold a permission hold keeps open (hold_tool_call)`.
- New method. It replaces the queue logic in `_render_block_fold` and
  `_settle_block_fold`:

  ```lua
  --- Queue the fold state a tool call block should have, when it differs
  --- from the state last queued: open when its layout wants it open or a
  --- permission hold reveals it, else closed. No-op for a block without
  --- a fold.
  --- @param block agentic.ui.MessageWriter.ToolCallBlock
  function MessageWriter:_sync_block_fold(block)
  ```

- `_render_block_fold(block, start_row, fold)`: place the anchor, set
  `block.fold_open = fold.state == "open"`, then `_sync_block_fold(block)`.
  `fold_sent` is nil after `_drop_block_fold`, so a re-render always
  queues. This is required because a replaced fold keeps its old flag.
- `_settle_block_fold(block, open)`: set `block.fold_open = open`, then
  `_sync_block_fold(block)`. Callers do not change.
  `_write_status_and_settle_fold` keeps its final-status gate. This covers
  a diff that fails with no reason and keeps the same text: the content is
  unchanged, but the layout state changes from open to closed.
- `ToolCallBlock` docs: `fold_sent` is "The state last queued for the
  anchor; nil before the first sync."

### 3. The permission hold reveals the held block

- `hold_tool_call(tool_call_id, reveal)`. Add `--- @param reveal boolean
  Keep the block's fold open until release_hold`. Set
  `_revealed_tool_call_id = reveal and tool_call_id or nil`, and sync the
  block if it is tracked. A block rendered later picks this up in
  `_render_block_fold`.
- `release_hold`: clear `_revealed_tool_call_id` and sync the block it
  named.
- `permission_manager.lua`:
  - The request's own hold (in the open path and in the writer re-anchor)
    passes `true`.
  - `_sync_proxy_hold` passes `false`. The proxy holds the subagent's Task
    block, whose body is the subagent's prompt, and it toggles as windows
    change.

### 4. Read-only classifier (`permission_rules.lua`)

- Move the body of `M.evaluate` after the argument and size checks into a
  local function:

  ```lua
  --- @param command string
  --- @param rules { allow_settings: agentic.utils.PermissionRules.CompiledPattern[], allow_remembered: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], tier: agentic.PermAutoApproveTier, read_scripts: boolean }
  --- @return boolean ok
  --- @return agentic.utils.PermissionRules.Effect[] effects
  --- @return table<agentic.utils.PermissionRules.Source, true> sources
  local function run_walk(command, rules)
  ```

  `M.evaluate` keeps its signature and behaviour, and passes
  `read_scripts = true`.
- `WalkCtx` gains `read_scripts: boolean`. In `walk_command`, a
  `script_path` with `not ctx.read_scripts` returns false before any disk
  read or `parse_zsh_untrusted` call.
- New:

  ```lua
  --- Whether a command only reads: every leaf passes a structured
  --- `read_only` gate, no structured deny or ask gate matches, and it has
  --- no file-mutating effect. Settings.json rules, remembered leaves and
  --- `auto_approve_tier` do not count. A script it runs or sources makes it
  --- not read-only; the function reads no file but the structured rules.
  --- For display, never for approval. Memoised per command.
  --- @param command string
  --- @return boolean
  function M.is_read_only(command)
  ```

  It does the argument and size checks of `evaluate`, then `run_walk` with
  empty allow, deny and ask, tier `"read_only"`, `read_scripts = false`.
  It returns `ok and #effects == 0`. Results are cached in a module-local
  `cached_read_only` table that `M.invalidate_cache` clears.

### 5. Docs

- `config_default.lua`: `@field search_max_lines integer Fold search output,
  and execute output that only reads (structured read_only rules), past
  this many lines. 0 disables.`
- `doc/agentic.txt` (`search_max_lines`): the same description. Point to
  the permissions section for "only reads".
- `rendering` skill: § Fence info-strings, execute row: `search_max_lines`
  when the command only reads. § Body folding: `FoldState` is `open` |
  `closed`, due at render. Remove "Fetch/WebSearch close at a final
  status". Add one line: a new fold copies the flag of the fold before it,
  so the writer queues every state.

### 6. Tests

- `tool_call_layout.test.lua`: replace `closed_when_final` with `closed`.
  New cases:
  - `execute` `rg foo | head` with rows past `search_max_lines` and below
    `execute_max_lines` → `closed`.
  - `git commit -m x` with the same rows → no fold.
  - `rg foo > out` → no fold.
  - A large create diff → `closed`.
- `message_writer.test.lua` (window with `ChatBuffer.win_opts`):
  - A long execute body that arrives in an `in_progress` update is closed
    after the flush. The `completed` update queues nothing.
  - A fold rendered below a block opened with `:foldopen` is closed after
    the flush.
  - An open diff that re-renders as failed is closed.
  - A diff that fails with no reason and unchanged text is closed.
  - `hold_tool_call(id, true)` before and after render opens a closed
    diff, and `release_hold` closes it. `hold_tool_call(id, false)` queues
    nothing.
  - Update the existing `_pending_fold_ops` tests that assumed
    `closed_when_final`.
- `permission_manager.test.lua`: the proxy hold passes `reveal = false`.
- `permission_rules.test.lua`: `is_read_only` is true for `rg x`,
  `ls | wc -l` and `cat f 2>&1`. It is false for these:
  - `git add x`
  - `rg x > f`
  - a command that only a settings.json allow matches (stub
    `get_settings_patterns`)
  - `bash x.sh` and `source x.sh`, with an existing file; assert that
    `read_script` is not called
  - an empty string and an unparsable command

  A second call with the same command does not walk again.
- Run `tests/integration/test_insert_mode_folds.lua`,
  `test_native_subagents.lua` and `test_render_anywhere.lua`. Update them
  where they assert a body is open before its final status.

Commit 1: § 1 (without the execute threshold), § 2, § 3 and their tests.
Commit 2: § 4, the execute threshold, § 5 and their tests.

## Expected outcome

- Long output, fetch and WebSearch bodies are closed in the write that
  adds them. The final status does not close a fold, so no empty rows
  appear under the last line.
- `execute` output that only reads (`rg`, `ls`, `git log`) folds past
  `search_max_lines` (8) instead of `execute_max_lines` (25), whatever
  approved the call.
- Edit diffs open at render, as before. A large created file is open while
  its own permission prompt shows, and closes after the answer.
- `zR`, `zM` and a user `foldlevel` behave as before.

## Non-goals

- Follow moving up after a shrink. The late closes that remain (insert-mode
  rebuild, release of a hold, manual `zc`) are accepted.
- Changing `foldlevel`.
- Streaming `execute` output (`PLAN-terminal-streaming.md`).
- Classifying MCP or `other` tools as read-only.
- `bug-create-fold-never-fires.md`.

## Open questions

None.
