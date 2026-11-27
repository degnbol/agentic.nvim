# Plan: one per-path grant step for Bash effects and file tool calls
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/ui/permission_manager.lua` — `_bash_effects_clear`,
  `_check_grant`, `_granted_pair`, `_kind_args`, `raw_input_path`,
  `raw_input_destination`, `decide`
- `lua/agentic/utils/grant_safety.lua` — `stat_snapshot`, `stat_unchanged`,
  `safe_for_kind`, `is_scratch`, `KindArgs`, `StatSnapshot`
- `lua/agentic/ui/permission_manager.test.lua` — "grant scopes"
- Skills: `permissions` (§ Grant scopes, safety properties 1, 3, 5),
  `implement`

## Background
Two producers feed one grant policy (`permissions` skill § Grant scopes):
Bash effects (`_bash_effects_clear`) and ACP file tool calls
(`_check_grant`). Each runs the same per-path chain on its own:
`_granted_pair` → `GrantSafety.stat_snapshot(orig)` → `_kind_args`, then
re-stats every path after the safety verdict. `_kind_args` takes its own
`stat_snapshot` of the path it reads, so each path is stat'ed twice before
the verdict. The chains also drifted: a relative path reads `relative path`
from one and `not in a grant scope` from the other.

Only the verdict step differs: a Bash delete of scratch clears on an earlier
write in the same command, and a move judges source and destination
together (`safe_for_kind("move", args)` with `args.dest`).

The pre-verdict snapshot and `_kind_args`' snapshot describe one file:
`fs_stat` follows symlinks, so `stat(orig)` and `stat(real)` agree at that
moment. Re-stat stays on `orig`, so a symlink retargeted during the check is
still caught when the new target differs in mtime or size (property 5;
`StatSnapshot` holds no inode). It also catches a retarget between
`GrantSafety.resolve` and the pre-verdict snapshot, which passes today:
both stats of `orig` see the new target while `_kind_args` read the old one.

## Changes
### `permission_manager.lua`
- `_kind_args(kind, orig, real, diff, exclude_id)` also returns the
  snapshot it takes:
  ```lua
  --- @return agentic.utils.GrantSafety.KindArgs args
  --- @return agentic.utils.GrantSafety.StatSnapshot snap of the path the state is read from
  ```
- New, replacing the copied chain:
  ```lua
  --- @class agentic.ui.PermissionManager.GrantTarget
  --- @field orig string Absolute, normalised path
  --- @field args agentic.utils.GrantSafety.KindArgs
  --- @field snap agentic.utils.GrantSafety.StatSnapshot Taken before the verdict

  --- One path a mutation touches, granted in literal and resolved form, with
  --- its file state.
  --- @param kind string Normalised tool kind acting on the path
  --- @param path string As the call or the command gives it
  --- @param diff { old?: string[], new?: string[], all?: boolean }|nil
  --- @param exclude_id string|nil See `_kind_args`
  --- @return agentic.ui.PermissionManager.GrantTarget|nil target
  --- @return string|nil reason `relative path` or `not in a grant scope`; nil with a target
  function PermissionManager:_grant_target(kind, path, diff, exclude_id)
  ```
  `_granted_pair` folds into it (its only callers are the two methods
  below; no test calls it): the relative-path test moves to the top of
  `_grant_target`, and the literal-then-resolved scope order the verdict
  plan sets is kept.
- `_bash_effects_clear`: per effect `_grant_target(eff.kind, eff.path)`,
  then the scratch or `safe_for_kind` verdict on `target.args`; then its
  re-stat loop over the targets. The `#effects == 0` early return goes (the
  loop gives `true` on none). Names and returns kept.
- `_check_grant`: `_grant_target` for the source and, for a move, the
  destination (reason `relative destination` / `destination not in a grant
  scope`), `dest = dest.args`, `safe_for_kind`, then one
  `stat_unchanged(target.orig, target.snap)` per target (`source changed
  during check` / `destination changed during check`). Names and returns
  kept.

### Callers to audit
`_kind_args`, `_granted_pair`: only the two methods above.
`_bash_effects_clear`: `_shell_verdict`. `_check_grant`: `decide`.

### Tests
Written first, in `permission_manager.test.lua` "grant scopes". "falls
through when stat changes between snapshot and approval" (edit) and "does
not clear a file that changes during the check" (Bash write) cover
property 5 now and pass unchanged. Added, each changing real files inside
the check window by wrapping `GrantSafety.safe_for_kind` (not by stubbing
`vim.uv.fs_stat` by call index: `vim.fs.root`, `GitFiles` and `FileSystem`
also stat):
- A move whose destination file is rewritten inside the window:
  `destination changed during check`.
- An edit through a symlink that is retargeted inside the window to a file
  of another size: refused.
- `GrantSafety.stat_snapshot` runs twice per target in total (once before,
  once at re-stat), not three times; counted over all calls, since `orig`
  and `real` differ under a symlink.

Then: an edit of a relative path gives `relative path` (was `not in a grant
scope`); the existing grant cases pass unchanged.

## Expected outcome
- Grant decisions are unchanged, except that a symlink retargeted between
  resolve and snapshot is now refused.
- One stat fewer per path.
- A relative file-tool path gives `relative path`, as a relative Bash effect
  does.

## Non-goals
- The checks themselves (`safe_for_kind`, `is_scratch`, git state).
- `_granted_pair`'s order of checks (set in de9b3b3).
- `_kind_args` reads `exists` for a delete or move through `fs_stat`, which
  follows a symlink, so deleting a link reports its target's state. Separate
  issue, unchanged here.

## Open questions
None.
