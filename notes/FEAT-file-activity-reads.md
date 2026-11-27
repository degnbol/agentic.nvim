# Plan: file activity lists files the agent read
Status: draft

## Relevant files
- `lua/agentic/ui/file_activity.lua` — `OP_RANK`, `OP_MARKER`, `OP_HL`
  (the `read` class already exists), `_all_rows`, `count`, `reconcile`,
  `render`
- `lua/agentic/session_manager.lua` — `_record_file_op`
- `doc/agentic.txt` § `agentic-file-activity`
- Tests: `ui/file_activity.test.lua`, `session_manager.test.lua`
- Skills: `provider-system` (read completed calls from the tracker)
- After `notes/FEAT-per-agent-file-activity.md`: a subagent's reads land
  in its own tally.

## Background
The panel has a `read` op class with a rank, a `·` marker and a highlight,
and `count` and `reconcile` already skip reads. Nothing records one:
`_record_file_op` returns for every kind outside `FILE_MUTATING_KINDS`.

For a read, `argument` holds the path only on some adapters: claude
(`rawInput.file_path`), codex (`locations[1].path`, `""` without one),
auggie (`rawInput.file_path`, else the title) and opencode
(`rawInput.filePath` on an `in_progress` update, `"pending..."` before it).
Gemini, mistral and cursor leave the provider's `title` there.
`CanonicalToolCall.split_read_range` moves a
trailing `(N - M)` off every read argument into `read_range`.

`_all_rows` takes a row's `op`, `seq`, `first_op` and `parsed` from all of
the path's ops. With reads in the log that is wrong:

- A read after an edit makes the row's `op` `read`: it moves to the read
  tier and shows `·`, hiding the edit.
- A read bumps `seq`, so the row gets the unseen `●`, which marks a change.
- A read before a create makes `first_op` `read`, so a created-then-deleted
  file no longer drops on reconcile.
- A read has no `source`, so it clears `parsed` and the `shell` suffix.

## Changes

### `lua/agentic/session_manager.lua`
- `_record_file_op`: a `completed` call whose normalised kind is `read`
  records `op = "read"`, no `ranges`, when
  `FileSystem.is_file(FileSystem.canonical_path(tracker.argument))`: a
  completed read means the file existed, so a title or `"pending..."` in
  `argument` is skipped. Map kind to op class in one place (`read` → `read`,
  `delete` → `delete`, the rest through `file_created`/diff) instead of a
  second early return. `read` stays out of `FILE_MUTATING_KINDS` (it gates
  `checktime`). Update the docstring.

### `lua/agentic/ui/file_activity.lua`
- `_all_rows`: `op`, `seq`, `first_op` and `parsed` come from the path's
  mutations only. A path with only reads gets `op = "read"`,
  `first_op = "read"`, `seq = 0` (never unseen), `parsed = false`.
  `ranges` stays the union of every op's.
- `Row` field docs: `op` is the newest mutation's class, else `read`;
  `first_op` the oldest mutation's class, else `read`; `seq` the highest
  mutation seq, 0 when there is none; `parsed` every mutation has
  `source == "parsed"`, false when there is none.
- `FileActivity` class docstring: files the agent read or changed.
- `mark_viewed` unchanged: its watermark is the highest seq of any op, so it
  is at or above every row's `seq`.

- `reconcile` unchanged: a reverted path's row is hidden whole, its reads
  with it.

### `doc/agentic.txt` § `agentic-file-activity`
- First paragraph: files the agent read are listed too.
- Row table: `` `· path` `` — file read.
- Keys table: `<CR>` opens the first recorded change, else line 1.

### Tests
- `file_activity.test.lua`: edit then read keeps `~` and the mutation tier;
  read-only path renders `·` with no unseen mark; read, create, delete
  drops on reconcile; parsed write then read, and read then parsed write,
  keep `shell`; read then edit is in the mutation tier, `first_op = "edit"`,
  unseen; `count` excludes a read-only path (exists).
- `session_manager.test.lua`: a `completed` read of an existing file
  records `op = "read"`; a title-shaped `argument` records nothing; an
  `in_progress` or `failed` read records nothing. Remove `read` from the
  "ignores non-mutating kinds" list.

## Expected outcome
- A file the agent read and did not change shows as `· path` below every
  changed file, with no unseen mark.
- A file the agent read and changed shows as before.

## Non-goals
- Line ranges of a partial read (the tracker's `read_range`): `<CR>`
  opens a read row at line 1.
- Search results (`kind == "search"`): the argument is a pattern, and the
  matched files exist only in provider-formatted output.
- Reads on gemini, mistral and cursor: their adapters leave the title in a
  read's `argument`, so the `is_file` check skips them. Setting it from
  `locations[1].path`, as gemini does for edits, is an adapter fix.
- Reconciling read rows: a file read and later deleted keeps its `·` row.

- A setting to hide reads.

## Open questions
None.
