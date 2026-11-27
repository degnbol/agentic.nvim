# Plan: file activity infers shell-command changes from git
Status: draft

## Relevant files
- `lua/agentic/utils/git_files.lua` — `dirty_paths`, `index_key_of`
- `lua/agentic/ui/file_activity.lua` — `Op.source`, `Row.parsed`, `render`,
  `reconcile`, `is_reverted`
- `lua/agentic/session_manager.lua` — `_record_file_op`, `_record_shell_ops`,
  `_on_tool_call`, `_on_tool_call_update`, `_finalize_turn`,
  `_end_open_tool_calls`, `_reset_conversation`, `on_disconnect`,
  `_session_epoch`, `_replaying`, `_cwd`
- `lua/agentic/config_default.lua` — `windows.activity` and its class
  annotation
- `doc/agentic.txt` § `agentic-file-activity`
- `.claude/rules/session-isolation.md`
- Tests: `utils/git_files.test.lua`, `ui/file_activity.test.lua`,
  `session_manager.test.lua`
- Related: `notes/BUG-project-root-from-process-cwd.md`
- After `notes/FEAT-per-agent-file-activity.md`: inferred ops are recorded
  through `_activity_for`, into the calling agent's tally.

## Background
The panel lists the files a shell command names in a redirect or an `rm`
(`ShellParse.file_effects`, `source = "parsed"`). It misses every write a
program does itself: `sed -i`, `mv`, `cp`, `git rm`, `cargo fmt`, scripts.

Inside a git repository, `git status --porcelain -z` lists every path that
differs from HEAD or is untracked. One snapshot when an Execute call starts
and one when it ends give the candidate paths. Snapshot membership alone
does not say what happened on disk: `git commit`, `git add` and
`git reset --mixed` move paths between snapshots without touching a file,
and `rm` of a modified file keeps it in both. The decision is taken from
disk: whether the file exists at the end, whether it existed at the start
(read from the first snapshot's code), and its ctime against the start
time. ctime, not mtime: `mv`, `cp -p`, `tar x` and `touch -d` keep or set
an old mtime, but nothing sets ctime back, and staging does not change a
work-tree file's ctime.

When the call starts is not reported: claude-agent-acp sends the initial
`tool_call` as `pending` and sends `in_progress` only with a progress beat of
a long-running call (`tool-calls/renderer.js` `progress`). The first
notification of the call is the earliest known time; it is sent when the
tool input starts to stream (`renderer.js` `toolCall`), before the
permission prompt, so a save by the user while the prompt waits is
attributed to the call.

`git status` takes `index.lock` to refresh the index when it can. A snapshot
that runs while the agent's `git add` or `git commit` runs can make that
command fail; `--no-optional-locks` stops it.

Rejected alternatives: a recursive `fs_event` watch (event storms from
`.git/`, build directories and the user's `:w`); PostToolUse hooks (they get
the command string only).

## Changes

### `lua/agentic/utils/git_files.lua`
- `dirty_paths(git_root, opts, callback)`: runs
  `git --no-optional-locks -C <root> status --porcelain -z`, plus
  `--untracked-files=all` when `opts.all_untracked` (a new untracked
  directory is otherwise one `?? dir/` entry). Callback gets
  `table<string, string>|nil`: path → porcelain `XY` code; a rename's or
  copy's source gets `"D "`. Existing truthiness checks keep working.
- New pure function:
  ```lua
  --- @param before table<string, string> `dirty_paths` at the start
  --- @param after table<string, string> `dirty_paths` at the end
  --- @param since { sec: integer, nsec: integer } start time, `vim.uv.clock_gettime("realtime")`
  --- @return { path: string, op: "create"|"edit"|"delete" }[] changes
  function M.changes_between(before, after, since)
  ```
  For each path in either table:
  - existed at start: in `before` with no `D` in its code, or absent from
    `before` (clean and tracked) unless `after` gives `??`, `A` or `R` in
    `X` (new during the call).
  - absent at the end (`fs_stat` nil) and existed at start → `delete`.
  - exists and its ctime ≥ `since` → `edit` when it existed at start, else
    `create`.
  - otherwise not a change.

### `lua/agentic/config_default.lua`
- `windows.activity.infer_shell_changes = false`, and the field in the
  `agentic.UserConfig.Windows.Activity` annotation.

### `lua/agentic/session_manager.lua`
- Per-call state in an instance field `self._shell_watches`
  (`table<string, { since, before?, epoch }>`), never module-level.
- On the first notification of an `execute` call, when
  `infer_shell_changes` is set, `self:_replaying()` is not, and
  `vim.fs.root(self._cwd, ".git")` finds a root: store
  `vim.uv.clock_gettime("realtime")` and `_session_epoch`, and start the
  first `dirty_paths` (`all_untracked = true`).
- On the call's end (`completed`, or `failed` without
  `CanonicalToolCall.rejection_line`), after `_record_shell_ops`: when the
  first snapshot has returned, take the second, then record each
  `changes_between` entry with `source = "inferred"`. Each callback returns
  when `self.destroyed` or the epoch moved.
- Drop the call's entry on any end of the call. `_finalize_turn` drops the
  main chat's entries (a subagent's call can outlive the turn);
  `_reset_conversation` and `on_disconnect` drop all.
- `_record_shell_ops` runs first, so a path the text names keeps its
  `parsed` op (`FileActivity:record` dedupes on call and path).

### `lua/agentic/ui/file_activity.lua`
- `Op.source` gets `"inferred"`. `Row.parsed` becomes
  `Row.source: "parsed"|"inferred"|nil`: `parsed` when every mutation on
  the path is parsed, `inferred` when every one is parsed or inferred and
  one is inferred, nil when any came from a tool.
- `render`: `shell` suffix for `parsed`, `shell?` for `inferred`.
- `is_reverted`: `dirty` param type `table<string, string>`.
- `reconcile` calls `dirty_paths` with `{}` (untracked directories stay
  collapsed there).

### `doc/agentic.txt` § `agentic-file-activity`
- Rewrite the "marked `shell`" sentence in place to cover `shell?` and
  `infer_shell_changes`; document the option where the other
  `windows.activity` options are.

### Tests
- `git_files.test.lua`: `dirty_paths` returns `XY` codes, a rename's source
  as `"D "`, and every file of a new directory with `all_untracked`.
  `changes_between` against a temp repo: `rm` of a modified tracked file and
  of an untracked file → `delete`; `git mv a b` → `a` delete, `b` create;
  `touch x && git add x` → create; `git commit` and `git add` of an
  unchanged file → nothing; `mv` keeping an old mtime → recorded; a file
  dirty in both with ctime before `since` → nothing.
- `session_manager.test.lua` (snapshots stubbed): records `inferred` ops on
  `completed`; a rejected call, a call whose first snapshot has not
  returned, a callback after `/new` (epoch moved), a replay during
  `self:_replaying()`, and the setting off record nothing and start no snapshot
  where applicable; `_finalize_turn` drops main-chat entries only.
- `file_activity.test.lua`: `Row.source` for parsed only, inferred only,
  mixed, and with a tool op.

## Expected outcome
- With `infer_shell_changes = true`, a file an Execute call creates, changes
  or deletes inside the repository is listed even when the command text does
  not name it, marked `shell?`.
- `git commit`, `git add` and `git reset` list nothing.
- Off by default: no extra git process per Execute call.

## Non-goals
- Paths outside the repository, ignored paths, and any change outside a git
  repository.
- Attribution inside the call window: any write during it, by another
  Execute call, an Edit, a subagent or the user, is recorded for the call.
- Writes after the call ends: a `run_in_background` command, or a process
  the command left running.
- An interrupted command's partial writes (it ends with a rejection line).
- A command that ends before its first snapshot returns records nothing.

## Open questions
None.
