# Plan: record cwd that the command ends in
Status: reviewed spec

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `collect`, `collect_command`,
  `collect_unwrapped`, `collect_pipeline`, `CHILD_SHELL_TYPES`,
  `SAME_SHELL_PREFIXES`, `DIR_CHANGERS`, `VISIBLE_WRAPPERS`,
  `agentic.utils.ShellParse.WrapperSpec`, `skip_wrapper_operands`,
  `sets_option`, `shell_command`, `function_names`, `runs_without_call`,
  `agentic.utils.ShellParse.Shell`, `agentic.ShellCommand` (`cwd`),
  `cd_target`, `command_cwds`, `extract_commands`
- `lua/agentic/utils/shell_parse.test.lua` — "stdin and cwd"
- Consumer (dotfiles repo): `~/dotfiles/config/claude/hooks/lib/checks/rm_targets.lua`
  (`locate`, `changes_dir_after`, `DIR_CHANGES`, header doc),
  `rm-refs-remind.sh` (resolves `?` against the end cwd); tests
  `tests/test-guard-runner.zsh`, `tests/test-rm-refs-remind.zsh`
- Skill: `permissions` (`references/parsing.md` § Script files)

## Background
`ShellCommand.cwd` is `false` when an earlier `cd` cannot be pinned
(`cd_target`: `cd -`, `cd "$d"`, `cd ~user`, a bare `cd name`). `rm_targets`
reports an operand under `cwd = false` as `?path`, which `rm-refs-remind.sh`
resolves against the directory the whole command ends in, unless
`changes_dir_after` finds a later `cd`/`pushd`/`popd` record. That
resolution is right only when the record starts in the directory the
command ends in. The flat record list cannot tell:

- a child shell may change directory before the record and ends before the
  command does: `(cd sub && rm x)`, `zsh -c 'cd sub; rm x'`; an action inner
  or a launcher with a directory option runs elsewhere
  (`find . -execdir rm x ';'`, `env -C /y rm x`, `sudo -D /y rm x`) — `?x`
  resolves against the wrong directory;
- `source s.sh`, `.`, `eval "$x"`, `emulate sh -c '…'`, a dynamic command
  name, a call to a function the command defines, `time cd /y` and an
  anonymous function (`() { cd /y }`) move the outermost shell without a
  counted `cd` record (zsh runs `time`'s command and an anonymous function
  in the current shell; `collect` gives both a fresh `Shell`);
- a loop re-runs the record after a later `cd` in its body
  (`for d in a b; do rm x; cd -; done`), and `break` can end it between a
  `cd` and the record;
- a `cd` inside a later subshell (`cd ~foo && rm x; (cd /y)`) does not move
  it, but the scan discards the correct `?x`.

`collect` already knows each record's shell, so it computes the answer once.

zsh's `command` runs an external command, never a builtin or function
(without `POSIX_BUILTINS`: `zsh -fc 'command cd /tmp; pwd'` prints the start
directory). So `collect`'s fresh `Shell` for it is right, and
`shell_command`'s `or name == "command"` is wrong: `command_cwds` reads
`command cd /x` as entering `/x`.

Claude Code writes the end cwd with `eval <cmd> && pwd -P >| <file>`: after
`exit`, `exec <cmd>` or a non-zero exit it reports a cwd other than the
shell's end directory.

## Changes
`shell_parse.lua`:
- `SAME_SHELL_PREFIXES` gains `time`; `shell_command` drops its
  `or name == "command"`.
- `collect` walks an anonymous `function_definition` (no `name` field) in
  the current shell: it runs where it stands. `CHILD_SHELL_TYPES` keeps the
  named form.
- `DIR_CHANGERS` moves above `collect_command`, which now reads it.
- `local function defined_functions(root, src)` → `table<string, true>|nil`:
  every name a named `function_definition` anywhere under `root` defines
  (`M.function_names` per definition). nil when `function_names` gives nil
  for a named definition (a name that is not a plain word), or a name is one
  `M.runs_without_call` reports (`chpwd`, `TRAPDEBUG`, …): zsh may then run
  its body after any record.
- `WrapperSpec` gains `chdir_opts? string[]`, options that set the inner's
  directory: `sudo` `-D`, `--chdir`; `env` `-C`, `--chdir`. An inner whose
  launcher has one before `i_inner` (`sets_option`) runs in `fork(shell)`
  with `cwd = false`, then `move`d. This also fixes `cwd` of
  `env -C /y rm x`, which now says the caller's cwd.
- `agentic.ShellCommand` gains `cwd_final? true`: the command starts in the
  directory the outermost shell ends in. nil when that is not certain.

### Directory token
`agentic.utils.ShellParse.Shell` gains:
- `dir: table` — identity of the directory the shell is in now; a fresh
  `{}` after each change that may move it.
- `dirs: table<agentic.ShellCommand, table|false>` — shared by every shell
  of one extraction: the `dir` each record started in, false when unknown.
- `functions: table<string, true>` — shared: `defined_functions`, or `{}`.

Functions:
- `local function fork(shell)` → `Shell`: a child shell with the same `cwd`
  and `dir` and the shared tables. Replaces every `{ cwd = shell.cwd }`:
  launcher inner (`collect_unwrapped` call), action inner, non-last
  pipeline element (`collect_pipeline`), `CHILD_SHELL_TYPES`, background
  statement.
- `local function move(shell)`: `shell.dir = {}`.
- `local function moves_shell(rec, functions)` → `boolean`: `rec` may leave
  its shell in another directory — its name is in `DIR_CHANGERS` or
  `functions`, it is `opaque` with a name in `SAME_SHELL_PREFIXES`
  (`eval "$x"`), or it is `emulate` with a `-c` flag. The record itself
  runs before its change.

Use:
- `collect_command` sets `shell.dirs[rec] = shell.dir` when it inserts
  `rec`, and calls `move(shell)` where it updates `shell.cwd` when
  `moves_shell(rec, shell.functions)`. The dynamic-name branch calls
  `move(shell)` after collecting its substitutions.
- A named function body and an action inner with `foreign_cwd` run in
  `fork(shell)`, then `move`d: their directory is unknown here.
- `LOOP_TYPES` (`for_statement`, `c_style_for_statement`,
  `terse_for_statement`, `while_statement`, `repeat_statement`,
  `select_statement`): `collect` notes `#out + 1` and `shell.dir` before
  walking one; when the walk changed `shell.dir`, it sets
  `shell.dirs[rec] = false` for each record the walk emitted.
- `extract_commands` starts from
  `{ dir = {}, dirs = {}, functions = functions or {} }` with
  `functions = defined_functions(root, src)`. When `functions` is not nil,
  each record gets `cwd_final = shell.dirs[rec] == shell.dir or nil`.

Nested children, launchers, pipelines and background statements need no
rule of their own: a child with no move keeps its parent's `dir`.
Conditionals need none either: outside loops and function bodies, walk
order contains every run order, so no move walked after a record means
none ran after it.

Tests ("stdin and cwd"): `cwd_final` at top level, through
`eval`/`builtin`/`time`, and in child shells with no earlier move
(`sudo rm x`, `rm x | cat`, `rm x &`, `(rm x)`, `(… | rm x)`,
`find . -exec rm x ';'`); present after `(cd /y)`, `command cd /y`, and in
`for d in a b; do (rm x; cd /y); done`. Absent after a later `cd`,
`source`, `eval "$x"`, `emulate sh -c 'cd /y'`, `time cd /y`,
`() { cd /y }`, `$cmd`, and a call to a defined function; absent everywhere
when the command defines `TRAPDEBUG() { … }`; absent after a `cd` in the
same child shell (`(cd sub && rm x)`, `zsh -c 'cd sub; rm x'`), in a
function body, in `find -execdir`, in `env -C /y rm x` and
`sudo -D /y rm x` (both also `cwd = false`), and in `rm x & cd /y`; absent
in a loop whose body changes directory, in the outermost shell
(`for d in a b; do cd "$d"; rm x; done`) and in a child
(`(for d in a b; do rm x; cd /y; done)`). `time cd /y && rm x` and
`() { cd /y }; rm x` give `rm` `cwd = "/y"`. `command_cwds` tests:
`command cd /x` leaves the set unchanged.

Hook side (dotfiles repo, separate commit): `locate` returns `?path` for a
`cwd = false` record only when `cwd_final` and no record is `exit`,
`logout` or `bye` or has `exec` in `via`; else nil. `changes_dir_after` and
`DIR_CHANGES` go; the header says "when the command ends in its
directory". Tests: `cd -; rm c.lua; cd /` still gives no target;
`cd ~foo && rm x.lua; (cd /y)` and `cd ~foo && sudo rm x.lua` give
`?x.lua`; `cd -; rm c.lua; source s` and `cd ~foo && rm x.lua; exit` give
none; "cd inside a subshell" (`test-rm-refs-remind.zsh`), which fails now,
passes.

## Expected outcome
- `(cd sub && rm gone.lua)`, `find . -execdir rm x ';'`, `env -C /y rm x`:
  no `cwd_final`, no `?` target.
- `cd ~foo && rm x.lua`, `cd ~foo && sudo rm x.lua`: `cwd_final`; `?x.lua`
  resolves against the end cwd.
- `cd ~foo && rm x; (cd /y)`: `cwd_final`.
- `cd ~foo && rm x; source s.sh`, `cd - && rm x; f` (with `f` defined in the
  command), `for d in a b; do rm x; cd -; done`: no `cwd_final`.
- `time cd /y && rm x`: `rm` has `cwd = "/y"`.

## Non-goals
- A single-value cwd for a bare `cd name`.
- Using `command_cwds` sets in the records.
- Functions defined inside an `eval`ed or `-c` string: their calls do not
  count as a change.
- Functions and aliases the shell has before the command runs (startup
  files, Claude Code's shell snapshot, e.g. zoxide's `z`), and aliases the
  command defines: their calls do not count as a change.
- `setopt autocd` bare-directory commands, traps set by `trap`.
- A non-zero exit status, and a cwd Claude Code resets to the project
  directory: the hook resolves `?` against the cwd it is given.

## Open questions
None.
