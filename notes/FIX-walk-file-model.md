# Plan: possible cwds and same-command writes for file-backed walks
Status: reviewed spec

## Relevant files
- `lua/agentic/permission_hook.lua` — `M.evaluate`, the PreToolUse hook
  entry; its payload carries `cwd`, dropped today (`tool_use_id` is already
  used, for `record_deciders`)
- `lua/agentic/ui/permission_manager.lua` — `decide`, `_try_auto_approve`,
  `_complete_request` (allow-always tally), `_apply_unapproved_highlight`,
  `clear`, the `_deciders` store (the lifecycle model for the cwd store),
  `_bash_effects_clear` (its docstring's cwd rationale)
- `lua/agentic/ui/permission_highlight.lua` — `apply` calls
  `tally_unapproved`
- `lua/agentic/utils/permission_rules.lua` — `evaluate`,
  `should_auto_approve` (tests only), `tally_unapproved`, `run_walk`,
  `walk_until_shadowed_settles`, `walk`, `tally_walk`, `walk_command` and
  `command_known_safe` (script recursion, action-host recursion via
  `parsed_actions`), `record_writes`, `script_body`, `walk_redirected` and
  `tally_redirected` (`ctx.written`), `walk_for`/`walk_while` and their tally
  mirrors
- `lua/agentic/utils/shell_parse.lua` — `resolve_against_cwd`,
  `script_file_source`, `cwd_after_cd`, `collect_command` and
  `agentic.utils.ShellParse.Shell` (the single-value cwd behind
  `agentic.ShellCommand.cwd`), `host_actions` (`foreign_cwd`)
- `.claude/skills/permissions/SKILL.md`, `references/parsing.md`
- `doc/agentic.txt` `*agentic-permissions-shell*`

## Background
The walker reads files at decision time (`zsh run.sh`, `source ./x.sh`) and
resolves them against nvim's cwd. `cd` is a plain `read_only` leaf, and the
walker keeps no cwd. Measured: with nvim cwd `/tmp/good`,
`should_auto_approve("cd /tmp/evil && zsh run.sh")` returns true; the walker
judged `/tmp/good/run.sh`, the shell runs `/tmp/evil/run.sh`.

The cwd a Bash call starts in is known to the Claude CLI and is sent to the
plugin: the PreToolUse hook the plugin installs for every Claude session
(matcher `Bash|Write|Edit`) receives the live shell cwd in its input, which
also covers worktree subagents and directory moves. The hook runs before
`canUseTool`, so the cwd it saw can be looked up by tool-use id when the same
call reaches `session/request_permission`. Other providers send no cwd; their
start is unknown.

Inside one command, control flow decides which `cd` ran, so a leaf has a set
of possible cwds. A file-backed body must be safe from every one.

A write earlier in the same command can change the file a later leaf reads;
`ctx.written` covers a redirect into the exact script path only.

An action of `find -exec`/`fd -x` runs in the host's cwd, or elsewhere when
`HostActions.foreign_cwd` is set (`-execdir`, `fd --base-directory`); the
walkers then set `read_scripts = false` for the action walk and
`collect_command` gives the actions an unknown cwd.

`agentic.ShellCommand.cwd` (from `extract_commands`) has no reader outside
`shell_parse.test.lua`.

## Changes
Start cwd:
- `permission_hook.lua` passes `payload.cwd` to `decide`, and calls
  `PermissionManager:record_bash_cwd(payload.tool_use_id, payload.cwd)` for
  every Bash call, whatever the verdict: a call the hook allows runs, and
  `notes/feature-file-activity-panel.md` reads its start cwd when it ends.
- `PermissionManager:decide(kind, tool_call, diff, cwd)`.
  `_try_auto_approve`, `_complete_request` and `_apply_unapproved_highlight`
  read the cwd recorded for the request's `toolCallId` (nil when none) and
  pass it to `decide` / `tally_unapproved`.
- `PermissionManager:bash_cwd(tool_call_id) -> string|nil` reads an entry;
  `PermissionManager:drop_bash_cwd(tool_call_id)` removes it.
  `SessionManager:_on_tool_call_update` drops the entry when the call reaches
  `completed` or `failed`, after the file activity has read it. `clear`
  drops all entries, as it does `_deciders`.
- `PermissionRules.evaluate(command, config_dir, cwd, extra_allow)`,
  `should_auto_approve(command, config_dir, cwd, extra_allow)`,
  `tally_unapproved(command, config_dir, cwd)`; `cwd = nil` means unknown.
  `PermissionHighlight.apply` gains a `cwd` parameter.

`shell_parse.lua`:
- `--- @class agentic.utils.ShellParse.Cwds { dirs: string[], unknown: boolean }`
- `M.cd_target(args, args_dynamic) -> string|false` — the directory a
  successful `cd`/`chdir`/`pushd` with these operands enters: absolute, or
  `./…`/`../…` relative (the caller joins it to each possible cwd). Replaces
  `cwd_after_cd`; `collect_command` uses it too. Known only for no operand
  (home), `~`, `~/…`, `/…`, `./…`, `../…` (lexical `..`, as zsh's logical
  `cd`). False for options, a dynamic operand, a bare relative name (it may
  resolve through `cdpath`), `-`, `~name`, `~+`, `~-`, `~N`, two operands,
  and `pushd` with no operand (it swaps the stack). This changes
  `ShellCommand.cwd` for `cd name` (now false) and `cd`/`cd ~` (expanded);
  only its tests read it.
- `M.command_cwds(root, src, start, source_cwds) -> table<integer, agentic.utils.ShellParse.Cwds>, agentic.utils.ShellParse.Cwds`
  — `start` is a `Cwds`; `source_cwds` is nil or the callback described
  under `source file` below. The second return is the set after the whole
  tree, which the callback returns for a sourced body. A pre-pass keyed by `command` node id, so `walk` and
  `tally_walk` share one implementation of the control-flow rules. Each
  statement yields a success set and a failure set:
  - `cd`/`chdir`/`pushd X`: success = `{target}` for an absolute target, a
    relative target joined to each member of before (`unknown` when before
    is), or `unknown` when `cd_target` is false; failure = before. `popd`:
    both `unknown`. Any other leaf: both = before.
  - `a && b`: `b` starts at success(a); failure = failure(a) ∪ failure(b).
  - `a || b`: `b` starts at failure(a); success = success(a) ∪ success(b).
  - `a; b`: `b` starts at success(a) ∪ failure(a).
  - `! a`: success and failure swap.
  - `if c; then t; elif …; else e; fi`: `t` starts at success(c), each
    `elif` condition and `e` at failure of the previous condition; the set
    after is the union of every branch's exit and, without `else`, failure of
    the last condition.
  - `case`: every item body starts at before; the set after is before ∪ every
    body's exit.
  - `{ …; }`: same shell; sets flow through.
  - A `for`/`while`/`until` or function body that contains a `cd`: every
    command inside and after it gets `unknown` unless all its `cd` targets are
    absolute, in which case the set is before ∪ the targets.
  - Subshell, `$(…)`, `<(…)`, `&`, and pipeline elements but the last: a copy;
    nothing flows back.
  - `source file`/`. file`: the set after it is the sourced body's exit set,
    from an optional `source_cwds(path, before) -> Cwds` callback. Without
    the callback, or when it returns `unknown`, the set is `unknown`.
    `permission_rules.lua` backs the callback with the script reading it
    already has (`file_bodies`) and a nested `command_cwds` over each body,
    so the cwd of a sourced body comes from the same read and parse the walk
    does.
  - A set over 8 members becomes `unknown`.
- `script_file_source` returns the operand as written; resolution and the
  `.zwc` sibling check move to `file_bodies`, per possible cwd.
- `resolve_against_cwd(path, cwd) -> string` — the cwd is a parameter;
  realpath the parent before collapsing `..`, because the kernel resolves
  `link/../x` physically.

`permission_rules.lua`:
- `WalkCtx.cwd_of: table<integer, Cwds>` from `command_cwds`, and
  `WalkCtx.taint: { set: boolean }`, one table shared by every ctx copy so
  nested walks write through it. `run_walk` and `tally_unapproved` create
  both inside the `walk_until_shadowed_settles` callback, so each run starts
  clean. Taint is set by: a write effect, a `ctx.written` entry, or any
  approved leaf that does not classify `read_only`. A loop body that sets
  taint is walked a second time with taint set from the start.
- Every re-parsed tree gets its own `command_cwds` pass: a `-c` body starts
  at the host leaf's set; an action-host body (`parsed_actions`) at the
  host's set, or `unknown` under `foreign_cwd` (the existing
  `read_scripts = false` and no-new-effects rules for it stay); a script body
  from `file_bodies` at that body's single cwd.
- Local `file_bodies(path, ctx, node) -> { src: string, cwd: string }[]|false`
  — one body per possible cwd: `false` when the set is `unknown`, or when
  taint is set and the body is not the one reconstructed in `ctx.written`.
  Replaces `script_body` in `walk_command` and `command_known_safe`, and
  reads `ctx.written` as `script_body` does; `TallyCtx` gains `cwd_of` and
  `taint`. `false` means bail. `FEAT-executed-code.md` later turns the choice
  of file into data.
- `record_writes(written, paths, content, cwds)`: a relative path under more
  than one possible cwd marks every candidate key `false`.

Docs: `_bash_effects_clear`'s rationale (relative effects never clear) stays,
and is reworded to the set-of-cwds reason. `*agentic-permissions-shell*`:
one sentence that scripts are judged from every directory the command may
be in.

## Expected outcome
- `cd /tmp/evil && zsh run.sh` walks `/tmp/evil/run.sh`.
- `cd /tmp/evil; zsh run.sh` walks both `/tmp/evil/run.sh` and
  `<start>/run.sh`.
- `cd /tmp/evil && false || zsh run.sh` walks both.
- `cd "$d" && zsh run.sh`, `cd sub && zsh run.sh`, `popd; zsh run.sh`, and
  `zsh run.sh` from a provider without the hook prompt; `zsh /abs/run.sh` and
  `cd /abs && zsh run.sh` still walk.
- `find . -execdir zsh run.sh \;` prompts; `find . -exec zsh ./run.sh \;`
  walks `<start>/run.sh`.
- `echo x > cfg; zsh run.sh` and `cargo fmt && zsh run.sh` prompt (taint).
- An allow-always on a Claude prompt for `cd /x && zsh run.sh` remembers the
  script's leaves, as today.

## Non-goals
- Grant effects with relative paths.
- Commands found through a PATH entry inside the tree (direnv, venv
  activation).

## Open questions
None.
