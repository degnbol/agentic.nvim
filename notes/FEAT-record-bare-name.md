# Plan: bare program name in shell_parse command records
Status: spec

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `collect_command` (the only site that
  builds a record: `name = cmd_name` in the record table; a launcher's or `-c`
  shell's inner reaches it through `collect_unwrapped`), the
  `agentic.ShellCommand` class, `strip_command_path`, `M.leading_path`
- `lua/agentic/utils/shell_parse.test.lua` — "record shape" tests
- `lua/agentic/utils/grep_highlights.lua` — `GrepArgs.parse(rec.name, …)` in
  `grep_invocations_in`
- `lua/agentic/utils/grep_highlights.test.lua` — `for_command` tests
- `lua/agentic/utils/grep_args.lua` — `M.parse(name, …)`, `TOOL_OF_COMMAND`
- `~/dotfiles/config/claude/hooks/lib/checks/helpers.lua` — `command_name`, and
  every module in that directory that calls it

## Background
`ShellCommand.name` comes from `strip_command_path`, which strips only a system
bin dir (`/usr/bin/grep` → `grep`) and keeps any other path (`./grep`). That
function exists for the permission walk in `permission_rules.lua`: a planted
`/tmp/evil/grep` must not match a `grep` allow rule. The permission walk calls
it on its own tree and does not read `ShellCommand` records.

Every reader of records asks which tool runs, not which file:
- `grep_highlights.lua` passes `rec.name` to `GrepArgs.parse`, whose
  `TOOL_OF_COMMAND[name]` lookup misses `./rg` and `/opt/x/rg`.
- The Claude hook checks route every comparison through their own
  `helpers.command_name` (basename); a module that forgets it skips `./tool`
  silently.

No reader needs the kept path, so the record's `name` becomes the bare program
name. A reader that later needs the path as written can get a `path` field
then; `M.leading_path` already gives it for the first command.

## Changes
- `shell_parse.lua`:
  - The record table in `collect_command` sets `name = vim.fs.basename(cmd_name)`.
    Launcher unwrapping and `VISIBLE_WRAPPERS` lookups keep using `cmd_name`.
  - `agentic.ShellCommand` field doc:
    ```lua
    --- @field name string the unwrapped inner command's file name, every directory stripped (`./x` → `x`, `/usr/bin/ls` → `ls`); empty when the word ends in `/`
    ```
- `shell_parse.test.lua` ("record shape"): `name` for a bare name, a system bin
  path, `./x`, `/tmp/evil/grep`, an unwrapped launcher (`timeout 5 ./x` → `x`),
  and a word ending in `/` (`bin/` → `""`).
- `grep_highlights.test.lua` (`for_command`): `./rg foo` and `./git grep foo`
  highlight like `rg foo` and `git grep foo`. `grep_highlights.lua` itself is
  unchanged.
- `~/dotfiles/config/claude/hooks` (separate repo, separate commit, after this
  lands): modules compare `rec.name`; delete `helpers.command_name`.

## Expected outcome
- `./rg pat` and `/opt/x/rg pat` get the same pattern highlighting as `rg pat`.
- Hook checks fire on `./tool` and `bin/tool` with no helper to remember.
- Permission matching is unchanged: it does not read records.

## Non-goals
- Changing `strip_command_path` or the permission walk.
- Unwrapping a launcher found by its bare name (`/tmp/evil/timeout 5 rm` stays
  opaque): a planted launcher's inner must not read as the real command.
- Resolving the program through `$PATH` or symlinks.
- A `path` field: no reader needs it yet.

## Open questions
None.
