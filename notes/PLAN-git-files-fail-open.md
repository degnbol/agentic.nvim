# Plan: grant safety refuses when git cannot answer
Status: reviewed, ready

## Relevant files
- `lua/agentic/utils/git_files.lua` (+ `git_files.test.lua`)
- `lua/agentic/utils/grant_safety.lua` (+ `grant_safety.test.lua`)
- `lua/agentic/ui/permission_manager.lua` (+ `permission_manager.test.lua`)
- `lua/agentic/ui/file_activity.lua` (other `is_tracked` caller; no edit)
- Skill: `.claude/skills/permissions/SKILL.md` § "Grant scopes" (properties 3, recoverability)
- Bug report: `notes/bug-git-files-fail-open.md`

## Background
Both claims in the bug report hold against the code.

1. **`git diff` failure reads as clean.** `diff_hunks` returns `{}` on a
   non-zero exit and logs nothing (`git_files.lua:130-132`).
   `PermissionManager:_kind_args` turns that into `has_unstaged_hunks = false`
   (`permission_manager.lua:644-646,671`), and `safe_for_kind` then approves
   `write`/`delete` as "tracked + clean" (`grant_safety.lua:539-542,555-558`)
   and `edit` the same way (`:571-572`). The existing test
   `git_files.test.lua:218` asserts this `{}` result. `git diff` without
   `--exit-code` exits 0 whether or not there are differences, so a non-zero
   exit is always an error (e.g. an unreadable object). Rare once `ls-files`
   has worked, but the result is a silent fail-open in a safety predicate.

2. **Same-second index change leaves the tracked set stale.** `load_cache`
   compares only `mtime.sec` (`git_files.lua:44-50,63-64`). A
   `git rm --cached foo` in the same second as the previous load leaves `foo`
   in the set. `git diff -- foo` on an untracked path exits 0 with no output,
   so `foo` passes as tracked + clean and a grant can approve a write or
   delete of a file git can no longer restore. `GrantSafety.stat_snapshot`
   already records `nsec` (`grant_safety.lua:466-471`).

Additional fail-open on the same path, not in the report: when `ls-files` (or
`rev-parse`) fails, `is_tracked` returns `false` (`git_files.lua:59-61,76-79,
102-104`) and logs only through `Logger.debug`. In `safe_for_kind` an
untracked file mostly fails closed ("file untracked"), but `is_scratch` is
`tmp and not tracked` (`grant_safety.lua:508-510`). So a tracked file under a
tmp root becomes scratch, and write/create/edit approve with no git check
(`:520,530,562`); a Bash delete of it skips `safe_for_kind` and takes the
tmp-cleanup branch (`permission_manager.lua:607-610`), which clears when an
earlier write in the same command targeted it.

Fix: make "git could not answer" a distinct value (`nil`), carry it into
`KindArgs`, and refuse there. One flag covers both producers (`_check_grant`
and `_bash_effects_clear`) because both build `KindArgs` through
`_kind_args`. `dirty_paths` already uses this nil-vs-empty contract and its
`Logger.notify` WARN (`git_files.lua:161-164,180-192`); the sync functions
adopt the same.

## Changes

### `lua/agentic/utils/git_files.lua`
- Cache key: replace `index_mtime` (field and `mtime_of`) with one string key
  of the index file's `vim.uv.fs_stat`: `mtime.sec`, `mtime.nsec`, `size`,
  `ino` (e.g. `index_key_of(path) -> string`, `""` when the file is missing,
  as `0` is today). One string keeps the hit test a single `==`. Git replaces
  the index by renaming `index.lock`, so `ino` differs from the previous
  index on every write, also where mtime is coarse (1 s, or jiffy-grained
  `nsec` on Linux ext4). libuv fills `ino` and `nsec` on macOS and Linux.
- `resolve_index_path`: on a non-zero exit, `Logger.notify` WARN with
  `git_root` and stderr (stderr is only available here). The `rel == ""`
  branch stays a plain nil.
- `load_cache`: on `ls-files` failure, `Logger.notify` WARN with
  `git_root` and stderr (replaces `Logger.debug` at `:77`). Keep the cached
  set untouched on failure (unchanged).
- `M.is_tracked(path, git_root) -> boolean|nil`: `nil` when `load_cache`
  returns nil (git could not answer). Docstring states the nil contract.
- `M.diff_hunks(git_root, path) -> agentic.utils.GitFiles.Hunk[]|nil`: on a
  non-zero exit, `Logger.notify` WARN (git_root, path, stderr) and return
  `nil`. Docstring states nil vs `{}` as in `dirty_paths`.

### `lua/agentic/utils/grant_safety.lua`
- `KindArgs`: new field `--- @field git_unknown? boolean Git could not report tracked state or unstaged hunks`.
- `is_scratch`: `args.tmp == true and not args.tracked and not args.git_unknown`.
- `safe_for_kind`: first statement returns `false, "git state unknown"` when
  `args.git_unknown` (`move` recurses into `edit` and `write` on `dest`, so
  the destination is covered). `git_unknown` is only ever set for an existing
  path (below), so a change that overwrites nothing (create, write of a new
  file, edit of a missing file) stays approved: it is recoverable without git.

### `lua/agentic/ui/permission_manager.lua` — `_kind_args`
- `tracked`: `nil` from `is_tracked` is kept as unknown; no git root stays
  `false`.
- `hunks`: replace the `(tracked and snap.exists) and diff_hunks(...) or {}`
  expression at `:644-646` with an explicit `if`. The `and … or {}` idiom
  maps a `nil` from `diff_hunks` to `{}`, which is this bug again.
  `hunks` stays `{}` when the file is untracked or missing, and is the
  `diff_hunks` result (possibly `nil`) otherwise.
- Set `git_unknown = snap.exists and ((tracked == nil) or (hunks == nil))`, then pass
  `tracked == true` and `hunks or {}` into the existing fields.
- No change to `_check_grant`/`_bash_effects_clear`: both go through
  `safe_for_kind` or `is_scratch`.

### `lua/agentic/ui/file_activity.lua`
No edit. `GitFiles.is_tracked` at `:325` sits in an `or`; `nil` is falsy like
`false`, so the row keeps its current outcome. Only the annotation type widens.
A failing `ls-files` now also shows the WARN here, once per row.

### `.claude/skills/permissions/SKILL.md`
- § "Grant scopes", property 3: add that a git failure on an existing file
  (tracked state or hunks unknown) refuses the grant and is never scratch.
- Paragraph on `git_files.lua` index path: "mtime-based cache invalidation"
  becomes invalidation on the index's stat key (mtime sec+nsec, size, inode).

### Tests
- `git_files.test.lua`:
  - The `fs_stat` fixtures (`:16` type, `:96`, `:147`) carry only `mtime`;
    add `size` and `ino` so the key is built from real fields.
  - Replace `:218` with "returns nil and notifies when git diff fails".
  - `is_tracked` returns nil (and notifies) when `ls-files` fails, and when
    `rev-parse` fails.
  - Cache invalidates when only `mtime.nsec` changes, and when only `ino`
    changes (same `sec`).
- `grant_safety.test.lua` (`describe("safe_for_kind")`, `:356`): each of
  write/delete/edit/move of an existing file refuses with `git_unknown = true`;
  `is_scratch` is false for `tmp = true, tracked = false, git_unknown = true`.
- `permission_manager.test.lua`: with `is_tracked` stubbed to nil, a granted
  write of a new file is still approved.
- `permission_manager.test.lua` (grant block, stubs at `:1093-1104`):
  - `is_tracked` stub returns nil → a granted ACP write under `tmp` prompts.
  - `diff_hunks` stub returns nil for a tracked file → granted write and a
    Bash `rm` of it prompt.

## Expected outcome
- A failure of `git ls-files`, `git rev-parse --git-path index` or
  `git diff` makes every grant check on that path fall back to the
  permission prompt, and shows a WARN notification with git's stderr.
- Any rewrite of the index invalidates the tracked-file set, also within the
  same second.
- No change when git works.

## Non-goals
- Deduplicating the WARN when git fails on many requests in a row (each
  failed check notifies, as `dirty_paths` does today).
- Changing `file_activity.lua` behaviour.
- Racing an index rewrite between `ls-files` and the stat (pre-existing; the
  next check reloads).
- Two index writes after a load that reuse the cached inode with equal
  mtime and size (possible only with coarse `nsec`). The index's trailing
  checksum would close this, but `index.skipHash` writes it as zeros.

## Open questions
None. Decided (user, 2026-10-26): `/grant` is about recoverable changes, and git is one way to recover. A change that overwrites nothing is recoverable without git, so a git failure refuses only changes to existing files.
