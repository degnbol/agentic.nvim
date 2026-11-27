# Plan: one approve walk; the tally is that walk with no effects pinned
Status: spec
Priority: P3
Depends: REFACTOR-leaf-classification.md, REFACTOR-redirect-effect.md

## Relevant files
- `lua/agentic/utils/permission_rules.lua` — the decision walk (`walk_command`
  through `walk`, `run_walk`, `evaluate`, `is_read_only`) and the tally walk (`substitution_inner_collect`
  through `tally_walk`, `tally_unapproved`); `redirect_writes`,
  `walk_until_shadowed_settles`, the `WalkCtx`/`TallyCtx` aliases, the
  "Tally walk" section header
- `lua/agentic/utils/permission_rules.test.lua` — "tally_unapproved", "tally
  of a script written earlier in the command", "decision sources",
  "is_read_only", every `should_auto_approve*`/`evaluate` describe
- `lua/agentic/ui/permission_manager.lua` — `_shell_verdict` (reads the tally,
  code unchanged)
- `notes/REFACTOR-leaf-classification.md`, `notes/REFACTOR-redirect-effect.md`
  (land first, see Dependencies)
- Skills: `permissions` (§ Shell command parsing, `references/parsing.md`),
  `implement`, `neovim`

## Background
`permission_rules.lua` walks the parse tree twice with one handler per node
type in each: the decision walk (`walk_command` … `walk`) stops at the first
part it cannot approve; the tally walk (`command_known_safe` … `tally_walk`)
records every such part as a range with a reason. Every tally handler names
the decision handler it "mirrors". Copied pairs: `walk_for`/`tally_for` (field
loop and unroll), `walk_case`/`tally_case`, `walk_statements`/
`tally_statements`, `walk_function_definition`/`tally_function_definition`,
`walk_substitution_inner`/`substitution_inner_collect`, the nested-walk
contexts in `walk_command`/`command_known_safe` (inline `-c` body, action
host), the context literals in `run_walk`/`tally_unapproved`, and the tally's
own leaf-recording block, copied between `tally_statements` and the `command`
branch of `tally_walk`.

The section header keeps them apart so that "a bug here can only mis-report,
never mis-approve". That property comes from the decision being
fail-closed (a path it does not model returns false), not from the copy: a
walk read as "no range recorded" is fail-open, since a path that forgets to
record approves. So the one walk keeps both results: every handler returns
`ok`, fail-closed as the decision handlers do today, and records ranges
without stopping. The copies have drifted, and the report is not only a
highlight: `_shell_verdict` gives the tally's ranges as the causes of an
undecided verdict, and has a branch for "The walk bailed on something the
tally does not model". Forms where the two disagree today:
- `[[ -f $(echo x) ]]`, `case $(echo a) in …`, a case pattern with `$(…)`:
  the walk refuses any substitution there; the tally checks a bare `$(…)`
  inner and records nothing when it is clean. The verdict then has one
  `structure` cause on the whole command.
- `arr=("$(echo hi)")`, `f=a$(echo b)c`: the walk refuses a substitution that
  is not a bare `$(…)` in value or element position; the tally's
  `record_substitutions` recurses into it and records nothing.
- A `for` with no body, a `while` with no condition or body, an unknown named
  child of a `case`: the walk refuses, the tally records nothing.
- A call to a function defined clean: the walk sets the taint only when the
  body's sources hold more than `read_only`; the tally always sets it.
- `sh -c 'echo hi' $(frob x)`, `f() { echo hi; }; f $(frob x)`, and a script
  operand followed by `$(frob x)` (`frob` unallowed): the walk refuses the
  argument substitution in `extract_args`; `command_known_safe` collects its
  ranges in `subst_ranges` and then drops them on the early `return true` of
  a recorded function call, a clean inline/wrapper inner, or clean
  executed bodies. The tally records nothing (reproduced). Read as "no range
  recorded", each of these would run `frob x` unprompted.

On a refused command find-all costs more than today: today the decision
stops at its first bail and reports its result final, so it runs once; in
one walk it visits every node, runs again for every new shadowed name, reads
every script, and `_shell_verdict` then runs the tally (a second full walk,
effects unpinned). On an approved command both walks visit every node
already. `is_read_only` (display, memoised) walks a non-read-only command to
its end.

The tally does not pin effects: a write redirect or an `rm` with concrete
operands is an unapproved part there (`redirect`, or the `rm` leaf's
classification), while the decision turns it into an effect for the grant
check. That difference is wanted (the highlight shows what may write), so it
stays, as one flag at the two sites that pin.

The reject walk (`reject_walk`/`command_is_denied`) is not a copy: it answers
"does any executed leaf concretely match a deny", fails open on what it cannot
read, and keeps `--` as the end of options. It stays.

## Changes
### `permission_rules.lua`
1. One context type replaces `WalkCtx` and `TallyCtx`: the union of their
   fields, with `tier` (the tally's name) in place of `auto_approve_tier`, and
   a new `pin_effects: boolean`. `effects`, `sources` and `leaves` are always
   present.
2. The tally handlers are the walk. Each `tally_*` function takes the name of
   the `walk_*` it mirrors (`tally_walk` → `walk`, `tally_sequence` →
   `walk_sequence`, `command_known_safe` → `check_command`, …) and the
   decision handlers are deleted after their duties below move in. The
   handlers keep the tally's `ranges` parameter and return `ok: boolean`
   with the decision handler's rule: false on any path it does not approve
   or does not model. A handler walks every child and records ranges even
   after its `ok` is false (no `and` short-circuit). `check_command` keeps
   its other returns after `ok`; its `ok` is false when an argument
   substitution is not ok, while extraction goes on. This holds on every
   path that returns early with `ok` true today: the `rm` carve-out
   (`rm x <(frob)` has a static `/dev/fd` operand), a recorded function
   call, an inline/wrapper inner, executed bodies. An inner, a body or an
   action walk is clean when its `ok` is true, never when it records no
   range. `walk_substitution_inner` (from `substitution_inner_collect`)
   returns, after `ok`, whether `extract_args` goes on; `check_command`'s
   `inner_check` closure keeps the first and returns the second:
   ```lua
   --- @return boolean ok every inner statement is ok
   --- @return boolean modelled the substitution has an inner statement and each is a statement type; extract_args bails when false
   function walk_substitution_inner(subst, src, ctx, ranges)
   ```
3. Duties of the decision walk that move in:
   - `ctx.sources`: `check_command` records the source of a safe leaf with
     `walk_command`'s precedence (structured allow kind, then `glob_allow`,
     then `session_allow`); `test_command`, an assignment and a function
     definition record `read_only`, as `walk` does.
   - `funcs` maps a name to the body's sources (`walk_function_definition`'s
     table), not `true`. A call adds those sources and sets the taint only
     when one is not `read_only`.
   - Under `ctx.pin_effects`: `walk_command`'s `rm` carve-out (delete
     effects, a recursive or directory or dynamic operand records the leaf
     with reason `structure`), and `walk_redirected`'s write effects
     (below).
   - A function body is walked with fresh `effects`, `sources`, `leaves` and
     `written`, and is clean when its `ok` is true and it adds no effect.
     Its ranges are dropped, as the tally does today.
   - An action host whose actions run in another directory records the leaf
     as `inner-code` when they added an effect (`walk_command`'s
     `actions.foreign_cwd and #ctx.effects > n_effects`).
   - `tally_unordered`'s re-run drops the leaves the first run added; it
     keeps the effects, as `walk_unordered` does, so effect results stay
     unchanged. It re-runs when the first run set the taint, also when that
     run is not ok (for the ranges), and its `ok` is the `ok` of both runs.
     A literal `for` unroll is ok when every value is.
4. `walk_redirected` (from `tally_redirected`): `redirect_writes` reports per
   redirect. Its returns become:
   ```lua
   --- @return { path: string, node: TSNode }[] writes write targets that resolve to a literal, as delivered, with their `file_redirect`
   --- @return string|nil content (unchanged)
   --- @return TSNode[] unresolved write redirects whose target does not resolve
   ```
   With `pin_effects`: each write is an effect (and sets the taint), each
   unresolved redirect records `redirect`. Without: both record `redirect`,
   as the tally does today. A file redirect `redirect_effect` cannot model is
   in `unresolved`. A herestring, a heredoc body with an expansion, and a
   word in `parts.words` that no recorded redirect contains record
   `redirect`. `record_writes` reads `writes[i].path`.
5. Where the two walks disagree (Background), the decision walk's rule is
   kept and the range it records is:
   - a substitution in `test_command`, a `case` value or pattern, or a
     non-bare position of an assignment value, array element or `for` item:
     `dirty-subst` on the substitution node. A bare position (an assignment
     value, array element or `for` item whose node is itself a
     `command_substitution`) is not a call of `record_substitutions`: the
     caller branches on the node type, as `walk` does today, and calls
     `walk_substitution_inner`; when its `modelled` is false the caller
     records `dirty-subst` on the node. `record_substitutions` no longer
     walks an inner, so it loses `src` and `ctx`:
     ```lua
     --- Record `dirty-subst` on every substitution in `node`.
     --- @param node TSNode
     --- @param ranges agentic.utils.PermissionRules.Range[]
     --- @return boolean ok `node` holds no substitution
     local function record_substitutions(node, ranges)
     ```
   - a `for` with no body, a `while` with no condition or body, an unknown
     named child of a `case`: `structure` on that node.
   - an argument substitution whose inner records a range: its ranges are
     recorded on every path of `check_command`, without exception. That
     includes the paths that return early with `ok` true today (a recorded
     function call, a clean inline/wrapper inner, clean executed bodies),
     every bail (deny/ask, `code-builtin`, `structure`, `dynamic`), and the
     not-safe path that returns a rememberable leaf. On that path the leaf's
     whole range and the substitution's ranges are both recorded (item 6).
6. `tally_statements` and `walk`'s `command` branch both call one recorder,
   replacing the copied block:
   ```lua
   --- Record a `command` leaf that is not known-safe: its sub-ranges when
   --- `check_command` gives them, else its whole range with the reason, and
   --- its rememberable leaf in `ctx.leaves`. The ranges of its argument
   --- substitutions are recorded in both cases.
   --- @param node TSNode
   --- @param src string
   --- @param ctx agentic.utils.PermissionRules.WalkCtx
   --- @param ranges agentic.utils.PermissionRules.Range[]
   --- @param known table<string, string>|nil
   --- @param funcs table<string, table<agentic.utils.PermissionRules.Source, true>>|nil
   --- @return boolean ok `check_command`'s `ok`
   local function walk_command(node, src, ctx, ranges, known, funcs)
   ```
7. One public run replaces `run_walk` and `tally_unapproved`'s body, so a
   test can read `ok` and `ranges` of one walk:
   ```lua
   --- @class agentic.utils.PermissionRules.Walk
   --- @field ok boolean The root handler's `ok`: true only when every part is approved
   --- @field ranges agentic.utils.PermissionRules.Range[]
   --- @field leaves string[]
   --- @field effects agentic.utils.PermissionRules.Effect[]
   --- @field sources table<agentic.utils.PermissionRules.Source, true>

   --- @class agentic.utils.PermissionRules.WalkOpts
   --- @field cwd? string Absolute directory the command starts in; unknown when absent
   --- @field read_scripts boolean false leaves code a command reads unread, so its leaf meets the rules as written
   --- @field pin_effects boolean A write redirect or `rm` operand is an effect, not an unapproved part

   --- Walk `command` under `rules` until the shadowed set settles.
   --- @param command string
   --- @param rules agentic.utils.PermissionRules.Rules
   --- @param opts agentic.utils.PermissionRules.WalkOpts
   --- @return agentic.utils.PermissionRules.Walk|nil walk nil when the command does not parse
   function M.walk(command, rules, opts)
   ```
   Every run settles: `walk_until_shadowed_settles` loses its `final`
   return, which has no other caller. `evaluate` keeps `run_walk`'s
   no-allow-source shortcut, calls
   `M.walk(command, rules, { cwd = cwd, read_scripts = true, pin_effects = true })`
   and returns `walk.ok`, the effects, and the sources when ok (false, `{}`,
   `{}` when nil). `is_read_only` calls it with
   `{ read_scripts = false, pin_effects = true }`. `tally_unapproved` calls
   it with `{ cwd = cwd, read_scripts = true, pin_effects = false }`; its
   returns are unchanged.
8. The "Tally walk" section header goes; the walk's header states the two
   results (`ok`, fail-closed, decides; `ranges` reports), the one flag, and
   that a missed range can only mis-report. Comments
   that say "mirrors walk_X" go with the copies.

### Tests (`permission_rules.test.lua`)
Written first, failing on today's code (`tally_unapproved` with the rules of
the "tally_unapproved" describe, `echo` allowed):
- `[[ -f $(echo x) ]]` → one `dirty-subst` range on `$(echo x)`.
- `case $(echo a) in a) echo b;; esac` → one `dirty-subst` range.
- `arr=("$(echo hi)")` → one `dirty-subst` range.
- `sh -c 'echo hi' $(frob x)` and `f() { echo hi; }; f $(frob x)` → one
  `no-allow` range on `frob x` each; `should_auto_approve` false for both
  (passes today, guards the merge). `rm x <(frob)`: `evaluate`'s `ok` is
  false (the `rm` carve-out, passes today).
- `rm $(frob x)` with `rm` and `frob` unallowed: two ranges (`rm $(frob x)`
  and `frob x`), one leaf, `complete` false. Today: one range, one leaf,
  `complete` true.
- Every command in the `should_auto_approve*` and `evaluate` describes, and
  the forms above: `M.walk(command, rules, { cwd = cwd, read_scripts = true, pin_effects = true })`
  gives `ok` false exactly when its `ranges` is not empty. Before the merge,
  check the direction today's code can (`evaluate`'s `ok` false ⇒
  `tally_unapproved` records a range); it fails only for the Background
  forms. The existing describes hold few of them, so the Background forms
  are added to the set.
- `f() { echo hi; }; f; <leaf that reads code>` (a leaf whose read
  `file_reader`/`may_run_config_code` gates on the taint), with `echo`
  read_only: the same ranges as the command without `f() { echo hi; }; f;`.

Then: every `should_auto_approve*`, `evaluate`, "decision sources" and
`is_read_only` case passes unchanged. "tally_unapproved" cases pass unchanged
except any that assert no range for the forms in Background.

## Expected outcome
- One handler per node type; the approve decision is the walk's fail-closed
  `ok`, and a range the walk misses can only mis-report.
- Approve, reject and effect results are unchanged. (On a refused command
  `evaluate` now returns every effect, not those before the first bail; no
  caller reads effects when `ok` is false.)
- The tally records a range for every part the decision refuses, so the
  undecided verdict names it instead of one `structure` cause on the whole
  command, and the prompt highlight shows it.
- `tally_unapproved`'s `complete` becomes false where a refused argument
  substitution sits inside a rememberable leaf: remembering the leaf does
  not approve the substitution's inner. `rm $(frob x)` with `rm` unallowed
  gives today 1 range, 1 leaf, `complete = true`; after, 2 ranges,
  `complete = false`. The undecided verdict lists the extra causes.

## Dependencies
After `REFACTOR-leaf-classification.md` (it rewrites the fronts and the
classification in `walk_command` and `command_known_safe`; this plan then
keeps one of them) and `REFACTOR-redirect-effect.md` (it changes
`redirect_writes`, `redirects_safe` and the tally's redirect branch, which
item 4 rewrites). `FEAT-permission-resolve-known-vars.md` edits the `-c`
recursion in both walks; after this plan it has one site.

## Non-goals
- The reject walk (Background).
- `_shell_verdict` reading causes from `tally_unapproved` rather than from
  the decision's own ranges.
- Showing an effect that clears a grant differently in the highlight.

## Open questions
None.
