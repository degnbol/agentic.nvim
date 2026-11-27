# Bug: project root comes from the process cwd, not the session's cwd

Found while keying session files on the session's cwd (commit 3f444ae).
Mechanism read from code.

## Mechanism

Neovim does a `chdir()` on each window change, to the effective cwd of
the new window. Thus `vim.uv.cwd()` is the cwd of the current window,
not the cwd of the session (`SessionManager._cwd`). After a `:cd`, a
`:tcd`/`:lcd`, or a change to a window with another cwd, these reads
give the root of another project:

- `FileActivity:_all_rows` (`file_activity.lua:191`): `vim.uv.cwd()`
  ranks rows by location.
- `FileActivity:reconcile` (`file_activity.lua:291`):
  `vim.fs.root(vim.uv.cwd(), ".git")` selects the repo for the
  reverted-file check.

## Fix direction

Give the session's `_cwd` to these reads, as `EnvironmentInfo.build`
takes it. `FileActivity` has no
reference to its session today, so it needs the cwd at construction or
per call.
