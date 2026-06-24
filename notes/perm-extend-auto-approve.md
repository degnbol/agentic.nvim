# Extending Bash auto-approval

> **Sequencing.** Builds on the shipped treesitter walker
> (`lua/agentic/utils/permission_rules.lua` + `permission_structured.lua`;
> overview in the `permissions` project skill). Each item below is an addition
> inside that walker, not a new subsystem. Grounded in the walker as of
> 2026-06-17.

## The invariant every item must preserve

An over-match may only ever *over-prompt*, never *under-prompt*. Dynamic tokens,
parse ambiguity, and unmodelled nodes already fail toward "ask". Every item here
widens what auto-approves and must be shown to keep that one-directional safety:
it may change *what a token is* or *which leaves are walked*, never *whether a
leaf is checked* against deny/ask.

Build order: **#3, #4, #5, #6** (preserve the invariant, no new config, broad
benefit; all done), **#7** (same tier — quoted-`"$var"` resolution, done) →
**#4b** (quoted `"$(cmd)"`, same tier, todo — see end of #4) →
**#1** (off by default, narrow) → **#2** (parked, see end).

A named `function_definition` already auto-approves *as a definition* (body not
walked — defining never runs it; an anonymous `() { … }` executes immediately
and bails). **#6** (done) builds on that to also approve *calls* to such
functions.

**#5 is done** (`shell_c_body` / `parse_zsh` + the `-c` branch in `walk_command`,
mirrored in `command_known_safe`; tests under "inline shell -c body").

**#4 is done** (`walk_substitution_inner` invoked from the bare
`command_substitution` argument branch in `walk_command` and the list-item
branch in `walk_for`; the spliced token is pushed dynamic; mirrored in
`command_known_safe` / `tally_for` via `substitution_inner_clean`; tests under
"#4 argument-position command substitution" plus a laundering case in the
use-site carve-out block).

**#3 is done (both grades)** (`walk_sequence`/`tally_sequence` thread a
per-sequence `known` env over `SEQUENCE_TYPES` + `do_group`, left to right;
`update_known` records a pure-literal assignment and otherwise hands the sibling
to `collect_bindings`; `walk_command`/`command_known_safe` resolve a bare
`$name`/`${name}` via `resolved_var_name` when `is_safe_literal`; tests under "#3
constant-literal propagation" + a tally case). The two post-review corrections (a
`printf` over-prompt fix + a soundness-coupling docstring/test; see "Follow-up
corrections" under #3) are also done. The capable grade — a control-flow-sibling
collect-targets scan instead of clear-all — is now done (`collect_bindings`
field-aware walk; see the "capable grade" sub-bullet under #3). Remaining:
#1, #2.

---

## #4 — generalise command-substitution recursion (done)

**Today.** `walk_command` bails on `subtree_has_substitution` (line ~918), so
any `$(...)` in argument position prompts. Only `walk_assignment` recurses into
a substitution (assignment value / array element), approving iff every inner
command approves.

**Change.** Generalise that recursion to two more positions:

- **Argument** (`ls $(git rev-parse --show-toplevel)`): route each
  `command_substitution` argument child through `walk_substitution_inner` (must
  approve), then push a **dynamic placeholder token** into the outer arg stream
  (`args` + `args_dynamic[i]=true`).
- **For-list** (`for f in $(ls)`): in `walk_for`, allow a substitution list item
  by recursing it through `walk_substitution_inner` per child (keep literal
  items literal); the body already treats `$f` as dynamic, so laundering is
  caught at the use site.

**Why it's sound.** Two independent requirements, both already enforceable:
1. the inner code *runs* (`ls $(rm x)` deletes `x`), so it must clear the same
   bar as a standalone command — `walk_substitution_inner` does this;
2. the *output* splices into the outer stream, so it must be a dynamic token —
   the existing dynamic-token wildcarding then makes `find . $(echo -exec rm)`
   bail (dynamic wildcards find's `-exec` deny) while `ls $(...)` approves
   (`{}` read_only gate matches regardless).

`ls $var` and `ls $(...)` become identical *from the outside* (opaque dynamic
token); they differ only *inside* (the substitution has inner code to vet).

**Follow-on (#4b, todo) — quoted command substitution `"$(cmd)"`.** Only the
*bare* `$(…)` argument is walked (line ~905 branch); a quoted `"$(cmd)"` is a
`string` node, falls to the generic arg branch, and bails on
`subtree_has_substitution`. So `ls $(git rev-parse --show-toplevel)` approves but
`ls "$(git rev-parse --show-toplevel)"` prompts — the same backwardness #7 fixes
for `"$var"`, still present for `"$(cmd)"`. Not a `resolved_var_name` change (that
returns a *literal*); this needs #4's machinery — extend the line-905
`command_substitution` branch to also peek into a single-named-child `string`,
run `walk_substitution_inner`, and push a dynamic token. Mirror in
`command_known_safe`.

**Stays bailed** (output becomes a control surface the dynamic-token machinery
can't guard):
- **command-name** `$(echo rm) x` — output *is* the binary (`DYNAMIC_NAME_TYPES`).
- **redirect target** `cat > $(echo f)` — output *is* a write path
  (`redirect_is_safe`).

**Touches.** `walk_command`, `walk_for`, `literal_token` (signal "recurse" for a
`command_substitution` arg child rather than returning nil). Mirror in
`command_known_safe` / `tally_for` for the highlight pass.

---

## #3 — flow-sensitive literal propagation (both grades done; follow-ups done)

**Today.** A `$var` is always dynamic — `f=/safe/dir; find $f` bails because the
dynamic `$f` flips `has_dynamic`, which wildcard-fires find's `-exec` deny gate.
Documented residual ("benign dynamic value over-prompts").

**Change.** Thread a **constant environment** through `walk`, scoped to one
straight-line statement sequence (a `list`, `do_group`, or branch body). Walk
each sequence left-to-right; on a pure-literal assignment record `known[var]=L`;
when resolving a `$var` token in `walk_command`, substitute the literal and mark
the token static.

**Soundness: invalidation defaults to clear, never enumerates.** The unsafe
direction is *under*-prompt, so `known` must shrink whenever a rebinding *might*
have happened — and enumerating "what rebinds `var`" undercounts, because the
rebinding constructs share no node type: `local d=…`/`typeset d=…` parse as
`declaration_command` (with a `variable_assignment` *child*), `printf -v d` and
`read d` as `command`, `(( d = 1 ))` as `arithmetic_expansion` — none surface as
a top-level `variable_assignment`, so a scan keyed on that type silently keeps a
stale `known[d]` and approves `find /danger`. Invert the rule: an element
**preserves** `known` only when provably inert; everything else clears.

- **Pure-literal `variable_assignment`** (`f=lit`) — record `known[var]=lit`.
- **Plain `command`** with no namespace-mutating builtin — preserves `known`;
  each `$var` resolves against it (literal + static) at token extraction.
- **Everything else** is handed to `collect_bindings`, which returns the names
  the sibling could rebind (dropped from `known`) or signals *clear-all*. Two
  grades, both now shipped:
  - *Lazy (sound, narrow):* the original form cleared `known` entirely on any
    non-assignment, non-plain-command sibling. Caught the common immediate case
    (`f=/safe; find $f`); over-prompted on interleaved control flow
    (`f=/safe; if c; then :; fi; find $f`).
  - *Capable (done):* `collect_bindings` field-aware walk. A binding-free
    control-flow sibling (`if true; then echo; fi`, a `[[ … ]]` guard, a loop
    over a different var) drops nothing and `known` survives; one binding
    enumerable names (an `if`-body `d=…`, a `for` loop var, `printf -v g`) drops
    exactly those; one whose targets can't be enumerated (a namespace-mutating
    builtin, arithmetic assignment, a `declaration_command`, a dynamic name, or
    any unmodelled node type) clears `known`. It recurses only statement
    positions (`while read x` clears via the recursed condition; `case $x in`
    skips the matched value) and stops at `SCOPE_BOUNDARY` nodes (subshell /
    `$(…)` bindings are sealed). The same `collect_bindings` also tightened the
    top-level `command` branch — `printf -v g` now drops only `g`, not all of
    `known`.

The resolved literal is fed through the **same** gate evaluation, so
`f=--exec; find $f` still hits find's deny. No cross-sequence propagation (a
nested block's bindings do not leak to its parent). `$HOME`/`$PWD`-style
expansion is a separate later step (env knowledge, not dataflow) — out of scope.

**Why it's the real value.** Commands with no deny/ask gates (`rg`, `cat`)
already approve with dynamic args; #3 only changes outcomes for commands where a
dynamic positional currently wildcard-fires a gate (`find`, `git`, `sort`).

**Touches.** New env threaded through `walk` and its handlers; `walk_assignment`
(record), `walk_command` (resolve at token extraction); `update_known` shrinks
the env via `collect_bindings`. Mirror in the tally walk is automatic —
`tally_sequence` shares `update_known` (UI-only — a stale binding there
mis-highlights, never mis-approves).

### Follow-up corrections (post-review, done)

The lazy grade shipped, then a review found one over-prompt and one
under-documented soundness coupling. Docs (`SKILL.md`, `references/parsing.md`)
were corrected in that review; the code + tests below shipped after.

**A. `printf` over-prompts (the only real cost of clear-all).** `update_known`
treats every `NAMESPACE_MUTATING` builtin — including `printf` — as clearing
`known`. But `printf` only rebinds via its `-v NAME` form; plain `printf "msg"`
(logging/formatting between an assignment and a use) is harmless and common, so
`f=/safe; printf "log"; find $f` needlessly prompts.

- *Change:* in `update_known`'s `command` branch, special-case `name == "printf"`
  — clear `known` only when a bare `-v` token appears among the node's args;
  otherwise fall through to *preserve*. Every other `NAMESPACE_MUTATING` name
  keeps the unconditional clear. ~3 lines.
- *Soundness:* a false positive (clearing when we needn't) only over-prompts;
  only a missed real `-v` could under-prompt. `printf` has no bundled or long
  form for this in bash or zsh — it is spelled exactly `-v NAME`, no `-vf`, no
  `--variable`. So scanning the node's children for a token equal to `-v` catches
  *every* assigning form (including a dynamic target `printf -v "$x" …` — the
  `-v` is still literally present, so we clear without inspecting the name).
  `printf '%s' -v` (printing the string "-v") over-clears — harmless, not worth
  parsing `--`/format position to avoid.
- *Scope:* `printf` is the **only** builtin needing this. Verified against the
  full `permissions.json`: the always-assigning builtins (`read`, `mapfile`,
  `set`, `unset`, `export`, `declare`, `let`, `eval`, `source`) are not
  allowlisted (they bail), `command` only approves `-v`/`-V` lookups (no
  execution, no rebind), and `cd`/`pwd` only mutate `PWD`/`OLDPWD` (theoretical
  `PWD=lit; cd x; cmd $PWD` residual — exploitability ≈ zero, and clearing on
  `cd` would over-prompt heavily; deliberately not actioned). Do **not** build a
  general carve-out mechanism — one `if name == "printf"` branch.

**B. Document the cross-file coupling.** Add one line to `NAMESPACE_MUTATING`'s
docstring stating the obligation it carries: *any builtin allowlisted in
`permissions.json` that can rebind a shell variable must appear here* — else the
preserve-on-plain-command branch under-prompts (the matcher resolves a stale
`known[var]` while the shell ran the rebound value). Today only `printf`
satisfies "allowlisted ∧ rebinds", which is why its membership is load-bearing,
not insurance.

**C. Fix the witness tests** (`permission_rules.test.lua`, "#3 constant-literal
propagation"):

- *Replace* `f=/safe; printf x; find $f` (asserts prompt, but `printf x` rebinds
  nothing — it passes for an incidental reason and the name "mutating builtin
  clears" misleads) **with** `f=/safe; printf -v f -- -exec; find $f` → must
  **prompt**. This locks coupling B: it fails if `printf` is ever dropped from
  the clear path. The `-exec` payload makes the threat legible, though the lock
  works regardless of the value (a stale-binding bug resolves `$f` to `/safe` and
  approves without ever inspecting printf's argument).
- *Add* `f=/safe; printf "msg"; find $f` → must **approve**, locking the
  over-prompt fix in A.

---

## #5 — walk the body of an inline `zsh -c '…'` (done)

**Today.** `permissions.json`'s `zsh` entry has `ask: [{options:["c","i","s","f"]}]`,
so every `zsh -c '…'` (and `bash -c`, `sh -c`) prompts unconditionally.

**Change.** When `cmd_name ∈ {zsh, bash, sh, dash}` and a `-c` flag is present,
take the following positional as the body. If it is a **pure literal**
(`args_dynamic` false), re-parse it with `get_string_parser("zsh")` and `walk`
it recursively; return that decision. Dynamic body (`zsh -c "$x"`), missing
body, or `-s`/`-i` → fall through to the existing **ask**.

**Why it's the better script win than #2.** The body is a literal already inside
`rawInput.command` — no file read, **no TOCTOU window** (the judged bytes are
the executed bytes), and the body token is already quote-stripped in `args`, so
it's feed-and-recurse. Soundness is identical to the top-level walk (same
parser, same fail-closed on parse error, same gates on inner leaves).

`-l`/`-f`/`-x` alongside `-c` are fine (shell behaviour, not Claude-injected
code). Add a small recursion-**depth cap** (~3) for `zsh -c 'zsh -c "…"'`.
A named function defined inside the `-c` body approves as a definition, but a
call to it bails without #6's function-walker — inline `-c` bodies are
overwhelmingly simple pipelines, though, so this fires without that dependency.

**Touches.** `walk_command` (shell-`-c` branch, before the structured ask so the
`c` gate doesn't pre-empt it); `ctx.depth` guard; mirror in `command_known_safe`.

---

## #1 — `rm` of Claude's own scratch (`scratch_rm`) (todo)

**Today.** `rm` is unconditionally `ask`; any non-`/dev/null` redirect bails. The
whole Bash system is path-agnostic — no notion of a safe path (only `/trust`,
for ACP file-edit kinds, is path-aware).

**Change.** A `scratch_rm` config enum (default `"off"`), mirroring
`Config.permissions.auto_approve`:

| value | a `rm <literal>` auto-approves when the resolved path is… |
|---|---|
| `"off"` (default) | never — scratch files persist as a record |
| `"authored"` | in the **session author-ledger** *and* under a temp root |
| `"temp"` | under a temp root (authored or not) |

- **Author-ledger** = the set of paths Claude wrote this session via write /
  create / edit tool calls, harvested from the in-plugin tracker
  (`message_writer.tool_call_blocks[*].argument` — the same field
  `_try_record_edit_range` reads). No SDK hook, no `session_id` correlation.
- **Temp root** = strictly *under* `/tmp` or `$TMPDIR` (macOS `$TMPDIR` is
  `/var/folders/…`, where `mktemp` actually writes).
- **rm caps**: never the bare root, never a path containing `..`, `-rf` only on a
  strict subpath; resolve `realpath` and require *both* the literal and its
  realpath in scope (symlink escape); TOCTOU re-stat before approving (reuse the
  `TrustSafety` gates that `/trust` already carries).
- **Composes with #3**: `d=/tmp/x; …; rm -r $d` resolves `$d`→`/tmp/x` first.

**Accepted residual.** `f=$(mktemp); echo x > $f; rm $f` — `mktemp`'s path is a
runtime-random value returned on stdout, never observed, never propagatable. So
mktemp-based scratch still prompts under any setting. This is unavoidable
without stdout capture.

**Why off by default.** Auto-approving a *destructive* op is more aggressive than
the existing `auto_approve_*` switches (which default `true` but only approve
non-destructive things), and a user may want scratch files kept as an audit
trail. The flag is a **preference gate**, not a safety gate — safety is fully
established by the ledger∩temp-root intersection.

**Touches.** `config_default.lua` (`scratch_rm`); `PermissionManager` (own the
author-ledger; build from the tracker); a scratch-`rm` resolver threaded into the
walk ctx and special-cased for `cmd_name=="rm"` in `walk_command`;
`TrustSafety`/`GitFiles` (reuse symlink + TOCTOU helpers).

---

## #6 — resolve calls to locally-defined functions (done)

**Was.** A named `function_definition` auto-approved *as a definition* (body not
walked). But a *call* was an ordinary `command` leaf — `foo` not in the
allowlist — so `foo() { grep x file }; foo` prompted on the call.

**Change (shipped).** `walk_function_definition` walks the body as a **fresh
sequence** (every `$var`/positional dynamic — no inherited `known` literals or
`funcs`); on a clean walk it records the name in a per-sequence `funcs` table
threaded alongside #3's `known` in `walk_sequence`. A later `command` whose name
matches a recorded entry approves in `walk_command` (after the deny/ask glob
gates, before the structured matcher). A redefinition with an unsafe body
**un-records** the name (`funcs[name] = walk(body) or nil`) — else a stale safe
record would approve a call that now runs the rebound body. Function bodies are
`compound_statement` nodes, so `walk`/`tally_walk` now route `compound_statement`
to the sequence walk (a brace group `{ …; }` runs like a `list` — sound, minor
bonus). Mirrored in `command_known_safe`/`tally_sequence` (UI).

**Why it's sound.** Shell functions have dynamic scope — the body runs with the
caller's variables and arguments, not the definition site's. So the body-walk
inherits *no* `known` literals and treats all params as arbitrary, which the
dynamic-token machinery already covers. A body that pipes `$1` into a gated
position (`foo() { find . $1 }`) fails closed at definition time and is never
recorded; a recorded function is therefore safe for **any** call arguments, so
the call site needs no re-vetting of its args (though a side-effecting argument
substitution `foo $(rm x)` is still walked and bails — it runs at the call
site). Only *which leaves are walked* changes — every body leaf is still checked
against deny/ask. Invariant held.

**Accepted residuals** (over-prompt, never under). `funcs` is per-sequence (same
scoping as #3's `known`): a call before its definition, in a nested `if`/loop
body, or to a function defined in a subshell does not resolve. Forward/mutual
recursion between functions does not resolve (each body-walk starts with empty
`funcs`).

**Enables #2.** This is the "function-definition walking" #2 names as its
prerequisite; with it in place, reading and walking a script *file* is the easy
part on top.

---

## #7 — resolve a standalone quoted `"$var"` (done)

Direct extension of #3: same `known` env, same gate evaluation, one more token
shape recognised.

**Was.** `resolved_var_name` matched only a *bare* expansion node — a
`variable_ref` / `expansion` / `simple_expansion` whose single named child is a
`simple_variable_name`. A double-quoted `"$base"` parses as a `string` node
wrapping that expansion (verified: `"$base"` → `string` > one `variable_ref`;
`"${base}"` → `string` > one `expansion`), so it falls through to the else
branch: `literal_token` emits the raw `"$base"` text and `token_is_dynamic`
flags it. The token goes **dynamic** and wildcard-fires any deny/ask gate at the
command, so `base=/path; find "$base"` prompts even though the bare
`base=/path; find $base` approves. The safer, guaranteed-single-word quoting
form gets the *more* conservative treatment — backwards.

**Change (shipped).** In `resolved_var_name`, one branch: a `string` node with
exactly one named child recurses on that child (`return resolved_var_name(child, src)`).
The inner `variable_ref` / `expansion` then passes the existing
`simple_variable_name` check. The `named_child_count() == 1` guard is what
excludes concatenation — `"pre$base"` carries a `string_content` sibling and
`"$a$b"` a second `variable_ref`, so both have ≥2 named children and stay
dynamic. Both call sites (the walk at ~922 and the tally mirror at ~1515)
consume `resolved_var_name`, so walk and highlight pick up the shape
automatically.

**Why it's sound (over-prompt only; invariant held).**
- Resolution still reads `known[kname]`, populated by `update_known` *only* from
  pure-literal assignments passing `is_safe_literal` — so the substituted value
  is always a splitting-proof single word, fed through the **same** deny/ask
  gates. `base=--exec; find "$base"` still denies (symmetry with the bare
  `f=--exec; find $f`).
- An unbound `"$base"` (kname set, `known[kname]` nil) falls through to today's
  dynamic path → no regression.
- Quoting suppresses word-splitting and globbing, so the quoted form can only
  ever yield exactly one token equal to the literal we substitute. This
  recognises a form we currently over-prompt; it does not widen the token-count
  surface.

**Stays bailed.** Concatenation (`"$base/dist"`), multiple expansions
(`"$a$b"`), a quoted command substitution (`"$(cmd)"` — inner child is
`command_substitution`, not an expansion type, so the recursion returns nil),
and any unbound var. All unchanged: dynamic → prompt.

**Touches.** `resolved_var_name` in `permission_rules.lua` (one recursive
branch, ~4 lines). No config, no new state. Update its docstring (drop "a quoted
`"$f"`" from the excluded-forms list) + `references/parsing.md` "Token
expansion" section (line ~64, same `"$f"` exclusion) + the `permissions` SKILL's
dynamic-expansion limitation bullet. Tally mirror automatic.

**Tests** (`permission_rules.test.lua`, "#3 constant-literal propagation"):
- `base=/safe/dir; find "$base"` → **approve** (the recovered case).
- `base=--exec; find "$base"` → **prompt** (deny resolves through quoting too).
- `find "$base"` (unbound) → **prompt** (no regression).
- `base=/safe; find "$base/x"` → **prompt** (concatenation not resolved).
- `base=/safe; find "${base}"` → **approve** (braced quoted form).
- `base=/safe; find "${base:-x}"` → **prompt** (richer expansion: the single
  named child is `expansion_default`, not `simple_variable_name`). Locks the
  non-resolution boundary against a future loosening of the guard.
- `base=/safe; find "$(echo x)"` → **prompt** (quoted command sub bails on
  `subtree_has_substitution`; also pins #4b from silently leaking in).

**Optional follow-on (parked) — relax `is_safe_literal` for the quoted
channel.** Because quoting suppresses splitting and globbing, a quoted `"$base"`
could safely resolve values carrying whitespace or glob metacharacters
(`base="my dir/*.js"` → one literal arg). That needs a second "quote-safe"
binding tier in `known` / `update_known` (today an assignment with a space is
never recorded) consulted only in quoted position — more machinery for a rare
value shape. Defer until a real case appears; the change above needs none of it
(a plain path already passes `is_safe_literal`).

---

## #2 — walk into script *files* (parked)

`zsh run-tests.zsh`: read the file, parse, walk. **Sound, not unsafe** — in this
architecture auto-approval fires synchronously with no human-wait window and ACP
runs tool calls sequentially, so the TOCTOU gap between the plugin reading the
file and the shell reading it has no writer in it.

**Blocked on bail rate, not safety.** With **#6** done, a call to a locally-
defined `foo` now resolves, but real scripts still bail on `source`, on a
harness command not in the allowlist (`nvim --headless`, `make`, `pytest`), or
on any write redirect. The scripts that pass are the trivial all-allowlisted
ones — already covered by a one-line `Bash(zsh run-tests.zsh)` allow in
`.claude/settings.json`.

The function-call-resolution prerequisite (#6) is in place; reading and walking
the file is the easy part on top (the #5 `-c` body-walk and a future file-read
share the "parse a body, recurse `walk`" shape, so a non-zsh extension needs no
major refactor). What remains for #2 to beat the one-liner is closing the
`source` / harness-command / write-redirect bail rate, not new walker machinery.

Revisit only when wanting general safe-script approval across many scripts.
