# Plan: file activity from shell commands (parsed writes)
Status: reviewed spec

## Relevant files
- `lua/agentic/ui/file_activity.lua` — `Op`, `Row`, `record`, `_all_rows`,
  `reconcile`, `load`, `render`
- `lua/agentic/session_manager.lua` — `_record_file_op`, `FILE_MUTATING_KINDS`
- `lua/agentic/utils/shell_parse.lua` — `extract_commands`, `agentic.ShellCommand`
  (`redirects`, `argv`, `argv_dynamic`, `cwd`, `opaque`),
  `agentic.utils.ShellParse.Redirect`
- `lua/agentic/utils/permission_rules.lua` — the `rm` operand loop in
  `walk_command`
- `lua/agentic/utils/file_system.lua` — `FileSystem.canonical_path`
- `lua/agentic/theme.lua` — `ACTIVITY_*` groups
- `doc/agentic.txt` § `agentic-file-activity`
- Tests: `ui/file_activity.test.lua`, `utils/shell_parse.test.lua`,
  `utils/permission_rules.test.lua`, `session_manager.test.lua`
- Skills: `permissions` (§ shell command parsing), `provider-system`
  (tracker reads), `session-lifecycle` (Path A replay)
- `PermissionManager:bash_cwd` (the hook-reported start cwd) and
  `ShellParse.cd_target` (what `ShellCommand.cwd` holds)

## Background
The panel (`64cbb2e`) records only edit-family tool calls. A file that the
agent writes or deletes through `Execute` (Bash) is not in it. Claude has no
delete tool, so every deletion goes through `rm`.

No signal is both exact and complete for a shell command:

- **Parsed writes** — exact but partial. `ShellParse.extract_commands` gives
  each command's redirects and arguments. It runs on every command text,
  including commands the SDK approves without a permission request. It misses
  writes that a program does itself (`sed -i`, `mv`, `cargo fmt`, a script).
- **git candidate set + mtime** — complete inside a repo, but inferred. It
  needs async git, a config flag, and it misattributes the user's own saves.

This plan does the parsed source. It needs no git and can land first.

Do not use `PermissionRules` effects for this. They exist only for commands
that reach a permission request and that the walker models fully, and they
bail on a recursive `rm`.

The tracker holds the command text in `argument` (the claude, codex,
opencode and auggie adapters set the command; gemini, cursor and
mistral-vibe set `update.title`, which may be a description, not a command).
Parsing runs for every adapter: the chat's execute fence already shows
`argument` as the command, and a description has no redirect or `rm` in
practice. Read it from the tracker, not from the `completed` update.

claude-agent-acp reports a call `failed` when the tool result has `is_error`
(`tool-calls/renderer.js` `resultStatus`), which includes a Bash non-zero
exit — after the command ran. A call that never ran (user rejection, denial,
interrupt) has `tracker.rejection` set (`__apply_rejection`). So parsed ops
are recorded on `completed`, and on `failed` without `rejection`.

Three things in the current panel break when one tool call can change more
than one path, or can delete:

1. `FileActivity:record` dedupes on `tool_call_id` only. The second path of
   one command is dropped.
2. `reconcile` marks a row reverted when the file is absent (non-git, or
   untracked and not dirty). For a delete row that is the wrong way round: the
   deletion is still there. No provider emits `kind = "delete"` today, so this
   path has not run yet. `GitFiles.dirty_paths` includes `??` entries, so an
   untracked file that is recreated is dirty.
3. Rows do not show where their ops came from. A parsed row is a guess from
   the command text, not a report from the tool.

## Changes

### `lua/agentic/utils/shell_parse.lua`
- New `M.rm_operands(argv, argv_dynamic)`:
  ```lua
  --- @param argv string[]
  --- @param argv_dynamic boolean[]
  --- @return { path: string, dynamic: boolean }[] operands
  --- @return boolean recursive -r/-R/-d or a long-form prefix of recursive/dir
  ```
  The operand/option split (`--`, lone `-`, GNU long-option prefixes) moves
  here from `permission_rules.lua`.
- New `M.file_effects(src, start_cwd)`:
  ```lua
  --- @class agentic.utils.ShellParse.FileEffect
  --- @field kind "write"|"delete"
  --- @field path string absolute or `~`-prefixed (not canonicalised)

  --- @param src string shell command line
  --- @param start_cwd string|nil absolute directory the command starts in; nil = unknown
  --- @return agentic.utils.ShellParse.FileEffect[] effects one per path, the last effect on it, in source order of that effect; {} when extraction returns nil
  ```
  One effect per path: a compound statement's redirect is on every record
  inside it (`{ a; b; } > f`), and `echo > f; rm f` nets to the delete.
  `PermissionRules.Effect` becomes an `@alias` of `FileEffect` (same shape).
  For each record of `extract_commands(src)`:
  - each redirect with `op` in `>`, `>>`, `>|`, `&>`, `&>>`, the clobber
    forms `>!`, `>>!`, `&>!`, `&>>!`, or `>&` with
    `target_fd == false`, and `dynamic == false` → `write`.
  - `name == "rm"`, not `opaque` → one `delete` per non-dynamic operand of
    `rm_operands(rec.argv, rec.argv_dynamic)`. A recursive `rm` records its
    operands too (the directory is the row).
  - Path: kept when it starts with `/` or `~`. A relative path is joined to
    the record's directory: `rec.cwd` when it starts with `/` or `~`;
    `rec.cwd` joined to `start_cwd` when it is relative; `start_cwd` when
    `rec.cwd` is nil. Dropped when `rec.cwd` is false, or the directory needs
    `start_cwd` and it is nil. Paths under `/dev/` are dropped.

### `lua/agentic/utils/permission_rules.lua`
- The `rm` loop calls `ShellParse.rm_operands`. It still bails when
  `recursive`, when an operand is dynamic, or when an operand ends in `/`.
  Behaviour is unchanged; the existing tests are the check.

### `lua/agentic/ui/file_activity.lua`
- `Op` gets `--- @field source? "parsed"` — absent means the tool reported
  the change. `record`'s param type gets the same field.
- Dedupe key becomes the pair (`tool_call_id`, canonical `path`). One local
  `op_key(tool_call_id, path)`; `_recorded` is keyed by it in `record` and
  `load`. Persisted ops already hold both fields.
- `Row` gets `--- @field parsed boolean` — true when every op on the path has
  `source == "parsed"`.
- `render`: a parsed row gets an end-of-line virt_text `shell` in new group
  `ACTIVITY_SOURCE`.
- `Row` gets `--- @field first_op agentic.ui.FileActivity.OpClass` — class
  of the path's oldest op.
- `reconcile`, for a row whose `op == "delete"`:
  - `first_op == "create"` and the file is absent → reverted (created and
    deleted again: no net change).
  - file exists and is not tracked (or no git) → reverted.
  - file exists, tracked, not dirty → reverted.
  - otherwise kept. A committed deletion stays: telling it from a deleted
    untracked file needs a HEAD lookup, not worth it here.
  Other rows keep the current rule.
- `<CR>` and `Q` on a delete row behave as on any row (vim opens a buffer
  for the missing path).
- Docstrings: `record` ("Idempotent in `op.tool_call_id`"), `_recorded`,
  `load`, `reconcile` describe the old key and rule — update them.

### `lua/agentic/theme.lua`
- `ACTIVITY_SOURCE = "AgenticActivitySource"`, linked to `Comment`.

### `lua/agentic/session_manager.lua`
- `_record_file_op`: split the body by kind before the
  `FILE_MUTATING_KINDS` return (`execute` is not in that table). New private
  `_record_shell_ops(tool_call_id, tracker)`: when
  `AcpKind.normalise(tracker.kind) == "execute"`, status is `completed`, or
  `failed` with no `rejection`, and `tracker.argument` is non-empty, call
  `ShellParse.file_effects(tracker.argument,
  self.permission_manager:bash_cwd(tool_call_id))` and record each effect:
  `write` → `op = "edit"`, `delete` → `op = "delete"`, `source = "parsed"`,
  no `ranges`. Edit-family handling is unchanged. Update the docstring.

### `doc/agentic.txt` § `agentic-file-activity`
- First paragraph: files changed by shell commands are listed when the
  command text names them (redirects, `rm`), marked `shell`.
- Row table: add `` `~ path  shell` `` — changed by a shell command, read
  from the command text.

### Tests
- `shell_parse.test.lua`: `file_effects` — `>`/`>>`/`&>` targets, `2>&1` and
  `>/dev/null` skipped, dynamic target skipped, `rm a b`, `rm -rf /x/d`,
  `rm -- -f`, relative path after `cd /abs` and after `cd ~/d`, relative
  path joined to `start_cwd`, `cd ./sub && rm x` joined to `start_cwd/sub`,
  relative with `start_cwd = nil` dropped, after `cd "$d"` dropped,
  `~/x` kept, `{ echo a; echo b; } > /x/e` gives one
  effect, `echo > /x/f; rm /x/f` gives one delete, unparsable command → `{}`.
  `rm_operands` directly.
- `file_activity.test.lua`: two paths from one `tool_call_id` give two rows;
  replay of the same pair is a no-op; `load` dedupes on the pair; each
  delete-row reconcile case above (non-git and git); parsed row renders the
  `shell` suffix, a path with one tool op does not.
- `session_manager.test.lua`: a `completed` execute call with
  `echo x > /tmp/a && rm /tmp/b` records an edit and a delete; `rm x` with
  a recorded bash cwd `/p` records `/p/x`, without one records nothing; a
  `failed`
  one without `rejection` records them; a `failed` one with `rejection`
  records nothing.

## Expected outcome
- `echo x > /abs/f` and `rm /abs/g` by the agent add `~ f  shell` and
  `- g  shell` rows. A later Edit of `f` drops the suffix.
- One command that writes several files adds one row for each.
- A deleted file's row stays until the file exists again, except a file the
  agent created and then deleted, which drops on the next open.
- Relative paths resolve against the start cwd that the PreToolUse hook
  reports (Claude only). For other providers and on a `session/load` replay,
  a relative path is not listed unless the command `cd`s to an absolute dir.
- Writes the command text does not show are not listed. A command that exits
  non-zero still lists its targets, also those a `&&` chain skipped.

## Non-goals
- **git candidate set + mtime source.** Per Execute call, `git status
  --porcelain -z` gives candidates and `fs_stat` mtime separates changed
  during the call from dirty before it. Lives in `utils/git_files.lua`
  (async there is new; `diff_hunks` diffs against the index). Behind a config
  flag; rows tagged `inferred`. Fails on non-git projects, ignored paths,
  files outside the repo, and the user's own saves mid-call. Not
  recursive `fs_event` (storms from `.git/`, build dirs, and the user's `:w`),
  not PostToolUse hooks (command string only). Own plan.
- **Reads** (`kind == "read"`). The `read` class, rank and marker exist.
  When they land: reads do not count toward any header count, and sort below
  every mutation. Own plan.
- **Search** (`kind == "search"`) is never recorded: the argument is a
  pattern, matched files exist only in provider-formatted output, and
  `files_with_matches` means the model did not see the contents.
- Forms the parsed source does not see: program writes (`sed -i`, `tee f`,
  `mv`, `cp`, `git rm`, `git mv`, `find -delete`, scripts), a bare `> f`
  (no command record), globs and braces (`rm /x/*.tmp`, `rm /x/{a,b}` are
  dynamic), `find -exec rm`/`xargs rm`.
- Create-vs-edit for redirects (the file exists by `completed`, so a
  redirect write is always `~`).
- `checktime` after a shell write (`execute` is not in
  `FILE_MUTATING_KINDS`).

## Open questions
None.
