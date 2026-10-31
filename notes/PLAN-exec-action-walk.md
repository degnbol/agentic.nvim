# Plan: walk into find/fd action commands
Status: reviewed spec

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `EXEC_WRAPPERS`, `VISIBLE_WRAPPERS`,
  `WrapperSpec.exec_action`, `FIND_ACTIONS`, `find_action_spans`,
  `inner_source`, `names_unseen_command`, `collect_command`
- `lua/agentic/utils/permission_rules.lua` — the three `inner_source` call
  sites: `walk_command` (approve walk), `command_known_safe` (tally: known-safe
  and pinpoint ranges), `command_is_denied` (reject walk)
- `lua/agentic/permissions.json` — `find` and `fd` entries
- Tests: `shell_parse.test.lua`, `permission_rules.test.lua`
- `permissions` project skill, `references/parsing.md` § Walk step 2
- `fd --help` (10.5.0) § `--exec`; find(1) (BSD on macOS, GNU on Linux)

## Background
`find -exec`/`-execdir`/`-ok`/`-okdir` and `fd -x`/`-X`/`--exec`/`--exec-batch`
run a command per match. The permission walk treats the words of that command
as arguments of `find`/`fd`, so it cannot classify them. `permissions.json`
therefore gates the action options as `ask`: every `fd -x file {}` prompts,
even when the command it runs is read-only.

The walk already re-walks the inner command of a transparent prefix
(`timeout`, `xargs`, `sh -c`). find and fd are not transparent: the host keeps
effects of its own (`find -delete`), so the host leaf and its action commands
must both pass. `extract_commands` already slices find's actions
(`exec_action`, `find_action_spans`) to report what runs; the permission walk
does not use that slice.

Grammar (BSD find and fd measured on macOS; GNU find per its manual):

| | find | fd |
|---|---|---|
| Action options | `-exec`, `-execdir`, `-ok`, `-okdir` | `-x`, `--exec`, `-X`, `--exec-batch` |
| End of an action | `;`; `+` directly after `{}`. BSD also ends at any word that *starts* with `;`, or with `+` after `{}` | `;`, or the end of the arguments |
| Placeholders | `{}` | `{}`, `{/}`, `{//}`, `{.}`, `{/.}`; `{{` and `}}` are escapes |
| No placeholder in the action | the action runs without a path | the path is appended |
| Working directory of the action | the match's directory for `-execdir`/`-okdir` | `--base-directory` if given, else the cwd |

Soundness hazards the design must close. Each was confirmed against a real
command that the naive slice approves while the tool deletes or runs more:
1. **Placeholders are runtime paths.** A literal `{//}` in `rm /tmp/{//}` would
   pin a grant-scope path, but `{//}` can be `../x`. A word that holds a
   placeholder becomes a dynamic token as a whole (substituting inside the word
   is wrong: in `'{}.bak'` a spliced `$var` stays literal text). Dynamic tokens
   wildcard deny/ask, never allow, and never pin a literal path.
2. **A dynamic word can end an action.** In `fd -x echo $t -x rm {}`, `$t` can
   expand to `;`, so `rm` runs as a second action that the slice did not see.
3. **Terminator spellings differ.** In `find . -exec sort + -o out {} \;` the
   `+` is an argument, so `sort … -o out` writes. On BSD,
   `find . -exec cat ';x' -delete -exec cat {} \;` ends the first action at
   `;x`, so `-delete` runs. Rule that fails closed on both: an action word that
   starts with `;`, or that starts with `+` directly after `{}`, but is not
   exactly the terminator, makes the slice unresolved.
4. **A host option can take the action option as its value.**
   `fd --and -x cat -x rm {}` (`--and` takes `-x`) and
   `find -f -exec cat -exec rm {} \;` (BSD `-f` takes a path) run `rm`.
   Rule: an action option directly after a dash-word that is not a known
   valueless option (or after `--`) makes the slice unresolved. A
   self-contained `--opt=value` is fine. This needs a flag list per host, not
   a list of every valued option.
5. **A foreign cwd moves paths.** With `-execdir`/`-okdir` or fd
   `--base-directory`, a relative path in the action (`rm foo`, `> out`,
   `sh x.sh`) resolves in another directory than the walk assumes. A
   foreign-cwd inner must add no path effect and read no script.
6. **fd escapes.** In `'{{}}'` fd delivers a literal `{}` and appends the path;
   `{{x}}` delivers `{x}`. A fd action word holding `{{` or `}}` makes the slice
   unresolved.

Placeholders, terminators and escapes are detected on the delivered word
(`args[i]`), not the source text.

When the slice does not resolve, the walk falls through to the host leaf with
all its arguments. The `ask` gates in `permissions.json` then prompt. They also
cover what the slice deliberately does not recognise: clustered short flags
(`fd -Hx`), `--exec=cmd`, and a dynamic host word that can expand to `-exec`
(`find $x …`, `find *`). They are not redundant after this change.

## Changes

### `shell_parse.lua`
- New class and table, next to `EXEC_WRAPPERS`:
  ```lua
  --- @class agentic.utils.ShellParse.ActionSpec
  --- @field opts table<string, boolean> tokens that start an action
  --- @field flag_opts table<string, boolean> valueless options an action option may follow
  --- @field foreign_cwd_opts table<string, boolean> action options that run in the match's directory
  --- @field chdir_opts table<string, boolean> host options whose value becomes every action's cwd (fd `--base-directory`)
  --- @field plus_ends boolean `+` directly after `{}` ends an action
  --- @field open_ended boolean the last action may run to the end of the arguments
  --- @field placeholders string[] substrings replaced by a match's path
  --- @field escapes string[] substrings that make the slice unresolved (fd `{{`, `}}`)
  --- @field appends_path boolean an action without a placeholder gets the path appended
  local ACTION_HOSTS = { find = …, fd = … }
  ```
  `flag_opts` for find: the valueless primaries and operators (`-print`,
  `-print0`, `-prune`, `-depth`, `-xdev`, `-L`, `-H`, `-P`, `-not`, `-a`,
  `-o`, `-and`, `-or`, …). For fd: its boolean flags from `fd --help`.
- `local function action_spans(args, args_dynamic, spec) -> { first: integer, last: integer, opt: string }[]|nil`
  — replaces `find_action_spans`. The range covers the words only, not the
  option or terminator. nil when an action is empty, a word inside an action
  is dynamic (hazard 2), a word breaks the terminator rule (hazard 3), an
  action option follows an unknown dash-word or `--` (hazard 4), a fd word
  holds an escape (hazard 6), or a non-`open_ended` action has no terminator.
  An option token inside an action is a word of it (`fd -x echo -x rm` runs
  `echo -x rm`).
- ```lua
  --- @class agentic.utils.ShellParse.HostActions
  --- @field inner string one action per line; each word that holds a placeholder is `$__exec_path`, other words keep their source text; an `appends_path` action without a placeholder ends with ` $__exec_path`
  --- @field args string[] the host's own tokens (no action option, word or terminator)
  --- @field arg_nodes TSNode[] parallel to `args`
  --- @field args_dynamic boolean[] parallel to `args`
  --- @field foreign_cwd boolean some action runs outside the cwd (hazard 5)
  ```
- `function M.host_actions(cmd_name, args, arg_nodes, args_dynamic, src) -> agentic.utils.ShellParse.HostActions|nil`
  — nil when `cmd_name` is not in `ACTION_HOSTS`, the host has no action, or
  `action_spans` returns nil.
- Remove `WrapperSpec.exec_action`, `VISIBLE_WRAPPERS.find`, `FIND_ACTIONS`,
  `find_action_spans` and the `exec_action` branch of `inner_source`.
- `collect_command`: when `inner_source` gives no inner, try `host_actions`.
  Emit the host record with the narrowed `args` as argv, then flatten `inner`
  with the host in `via`, and with `cwd = false` when `foreign_cwd`.
  `names_unseen_command` reads `ACTION_HOSTS[cmd_name].opts`.
- Docstrings that go stale: `VISIBLE_WRAPPERS` ("and `find -exec`"),
  `names_unseen_command` ("a find action"), `ShellCommand.argv_dynamic` (add
  `$__exec_path` beside `$__xargs_stdin`).

### `permission_rules.lua`
At each of the three sites, after the transparent-prefix block:
1. `host_actions(...)`; if nil, or `ctx.depth >= NESTED_MAX_DEPTH`, continue
   as today.
2. Re-walk `inner` at `depth + 1`:
   - approve walk: with `read_scripts = ctx.read_scripts and not foreign_cwd`.
     When `foreign_cwd`, fail if the inner grew `ctx.effects`. A failed inner
     returns false.
   - tally: a failed inner, or a foreign-cwd inner that runs a script, is not
     known-safe, with no pinpoint ranges (the inner is not a source substring,
     so it has no origin).
   - reject walk: a deny source from the inner is returned.
3. Continue to the leaf matchers. The structured matcher gets the narrowed
   `args`/`arg_nodes`/`args_dynamic`, so `find … -delete` still meets its deny
   gate and the action options no longer meet their `ask` gate. Settings globs
   and the remembered signature keep the full `leaf` (built before this block)
   at all three sites, so "allow always" keeps matching. Globs over the full
   leaf are sound: allow still needs the inner walk to pass, and deny/ask only
   over-fire.

### `permissions.json`
No change. See Background on why the `ask` gates stay.

### Tests
`shell_parse.test.lua` (`host_actions`):
- `find . -exec rm -f {} \;` → inner `rm -f $__exec_path`, args `{ "." }`
- two actions → two lines; `-print` after `;` stays in args
- `find . -exec sort + -o out {} \;` → one action `sort + -o out $__exec_path`
- `find . -exec rm {} +` ends at `+`
- `fd -x file` → `file $__exec_path`; `fd -x mv {} {.}.bak` → both words
  dynamic; `fd -x echo \; -H` → `-H` in args
- `-execdir`, `fd --base-directory d -x …` → `foreign_cwd = true`
- nil: `find . -exec rm {}`, `fd -x echo $t -x rm {}`, `fd --exec=echo`,
  `fd -Hx echo`, `find . -exec cat ';x' -delete -exec cat {} \;`,
  `find . -exec cat {} +x -delete -exec cat {} \;`,
  `fd --and -x cat -x rm {}`, `find -f -exec cat -exec rm {} \;`,
  `fd -- -x echo`, `fd -x echo '{{}}'`
- `extract_commands`: keep the find cases, now with a leading `find` record;
  add `fd -x rm {}` → `fd`, then `rm` via `fd`.

`permission_rules.test.lua`:
- approves: `fd -x file {}`, `fd -t f -X wc -l`,
  `find . -name '*.lua' -exec grep -n foo {} +`
- prompts: every nil case above; `fd -x sed -i s/a/b/ {}`;
  `find . -exec {} \;`; `fd -x {}`; `fd -e sh -x sh`;
  `find . $x rm {} \; -exec cat {} \;`; `find . -execdir rm foo \;`;
  `fd --base-directory d -x rm foo`; `find . -execdir sh x.sh \;` with a
  read-only `x.sh` written to the cwd first (so the test fails without the
  `read_scripts` rule)
- rejects: `find . -exec rm -rf {} \;`, `fd -x rm -f`,
  `find . -exec echo {} \; -delete`
- not rejected: `find . -exec echo -delete \;` (`-delete` is a word of `echo`)
- grant: `fd -x rm /tmp/{//}` does not clear the `/tmp` grant
- remember: after "allow always" on `fd -x file {}`, the same command
  auto-approves

### Docs
- `references/parsing.md` § Walk step 2: one sentence that find/fd actions are
  re-walked like a transparent prefix, and the host leaf is still checked
  without the action words.

## Expected outcome
- `fd -x file {}` and `find . -exec grep foo {} +` auto-approve at the
  `read_only` tier.
- An action with an ask-gated inner prompts. An action with a deny-gated inner
  rejects.
- An action that does not resolve prompts, as it does now.
- `find -delete` still rejects.
- `extract_commands` reports the host and its actions.

## Non-goals
- Pinpoint highlighting inside an action. The rebuilt inner is not a source
  substring, so the prompt highlights the whole host leaf.
- Recognising clustered short flags (`fd -Hx`) and `--exec=cmd`; the `ask`
  gate covers them.
- Constant propagation into actions: `c=rm; find . -exec $c …` sees `$c` as
  dynamic and prompts, like the `timeout` wrapper does.
- Modelling `-X`/`{} +` as many paths; one `$__exec_path` stands for all.
- Other hosts that run commands (`parallel`, `watch`, `git … -c`).

## Open questions
None.
