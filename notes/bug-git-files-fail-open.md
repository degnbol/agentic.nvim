# Bug: grant safety treats a dirty file as clean when git fails

Found by a read-only audit (2026-10-26); not reproduced.

## Observed in code
- `lua/agentic/utils/git_files.lua:130-132`: `diff_hunks` returns `{}` when `git diff` fails, and logs nothing. `has_unstaged_hunks` then reports no hunks, so a tracked file with unstaged changes counts as clean. A `/grant` scope can then auto-approve a write or delete on it, losing the unstaged changes.
- `git_files.lua:63-64`: the tracked-file set is cached on the index's `mtime.sec`. An index change within the same second (e.g. `git rm --cached`) leaves the set stale; a just-untracked file still takes the tracked-and-clean path. `GrantSafety.stat_snapshot` already compares `nsec`.

## Expected
A git failure makes grant safety refuse (fall back to asking), with the error visible. The tracked-set cache notices every index change.

## Related
- `permissions` skill (`.claude/skills/permissions/`), the /grant safety properties.
- `grant_safety.lua` callers of `GitFiles`.
