# Extending Bash auto-approval

> **Sequencing.** Builds on the shipped treesitter walker
> (`lua/agentic/utils/permission_rules.lua` + `permission_structured.lua`;
> overview in the `permissions` project skill). Every item but #1 is an addition
> inside that walker, not a new subsystem; #1 splits the walker into an effect
> producer and routes the effects through the existing `/trust` policy oracle.
> Grounded in the walker as of 2026-06-17.

## The invariant every item must preserve

An over-match may only ever *over-prompt*, never *under-prompt*. Dynamic tokens,
parse ambiguity, and unmodelled nodes already fail toward "ask". Every item here
widens what auto-approves and must be shown to keep that one-directional safety:
it may change *what a token is* or *which leaves are walked*, never *whether a
leaf is checked* against deny/ask.

Build order: **#3, #4, #5, #6** (preserve the invariant, no new config, broad
benefit; all done), **#7** (same tier — quoted-`"$var"` resolution, done) →
**#4b** (quoted `"$(cmd)"`, same tier, done — see end of #4) →
**#4b-general** (string-embedded `"text $(cmd)"`, sibling of #4b, done — see
end of #4) → **#4c** (process substitution `<(cmd)`/`>(cmd)`, same tier,
done — see end of #4) →
**#1** (tmp work unified into `/trust`; the one item that crosses out of the
walker into the trust/policy layer — step A writes + step B deletes both done,
the latter intra-command-only) → **#2** (parked, see end).

A named `function_definition` already auto-approves *as a definition* (body not
walked — defining never runs it; an anonymous `() { … }` executes immediately
and bails). **#6** (done) builds on that to also approve *calls* to such
functions.

Newest additions: **#8** (concatenation token shape — `$d/x` splices as one
token, static when its parts are known literals else dynamic) → **#9** (a
for-loop var over an all-literal list resolves per value through the gates;
depends on #8). **#8 first** — it unblocks the read-only majority; #9 recovers
gated commands (`find -exec`) inside literal loops.

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
#1, #2, #8, #9.

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

**Follow-on (#4b, done) — quoted command substitution `"$(cmd)"`.** A quoted
`"$(cmd)"` parses as `command > string > command_substitution`, so before #4b the
`string` landed in the `child:named()` arg branch and `subtree_has_substitution`
bailed — `ls $(git rev-parse --show-toplevel)` approved but
`ls "$(git rev-parse --show-toplevel)"` prompted, the same backwardness #7 fixed
for `"$var"`. Not a `resolved_var_name` change (that returns a *literal*); it
needs #4's machinery. Scope: command-**argument** position only; a quoted
for-list item (`for f in "$(ls)"`) stays bailed — extend if a case appears.

**Shipped.** `walk_command` (~900) and `command_known_safe` (~1504) kept two
byte-identical arg loops differing only in the inner-substitution checker
(`walk_substitution_inner` vs `substitution_inner_clean`). Both were extracted
into one `extract_args(node, src, ctx, known, inner_check)` →
`args|nil, arg_nodes, args_dynamic, name_node` (nil `args` signals bail),
collapsing the #4/#3/#7 arg-loop mirrors so #4b is a single-site edit (the
divergent gate/highlight tails stay in each caller). The guard lives in
`extract_args`'s `child:named()` branch as an `elseif` (no `goto`/`continue` in
Lua): a `string` with `named_child_count() == 1` whose lone named child is a
`command_substitution` recurses that inner through `inner_check` (it runs), then
splices the inner's `$(…)` text (quote-stripped, like the bare branch) as a
**dynamic** token. The three-part guard excludes `"pre$(cmd)"` and `"$a$b"`
(≥2 named children) and `"${x:-$(cmd)}"` (single child is `expansion`) — all stay
bailed via `subtree_has_substitution`. Quoting changes word-splitting
(`"$(cmd)"` one term vs `$(cmd)` zero-or-many) but the spliced content is unknown
either way, so the dynamic-token wildcarding gives the identical safety outcome.

Stays bailed regardless: command-name `$(echo rm) x` (output is the binary),
redirect target `cat > "$(echo f)"` (the `string` sits under `file_redirect`,
never reaches the arg loop).

**Tests** (`permission_rules.test.lua`, "#4b quoted command substitution"):
`cat "$(ls)"` → approve (the gate-free flip), `cat "$(nope)"` → prompt,
`cat "$(ls > out)"` → prompt, `cat "pre$(ls)"` → prompt (guard boundary),
`cat "$(echo $(ls))"` → approve (nested), `find "$(echo -exec rm)"` → prompt
(dynamic token wildcards find's `-exec` deny). `echo "$(rm -rf x)"` was dropped
from the non-recursed-bail list (now a recursed position). The #7
`find "$(echo x)"` assertion was kept with a relabelled rationale (post-#4b it
prompts on the gate wildcard, not the substitution bail).

**Docs updated:** `extract_args`/`walk_substitution_inner` docstrings, permissions
SKILL dynamic-expansion bullet, `references/parsing.md` recurse/bail lists. The
`resolved_var_name` docstring keeps `"$(cmd)"` in its excluded list (correct for
that helper — it resolves a literal name, not the substitution).

**Follow-on (#4b-general, done) — string-embedded substitution `"text $(cmd)"`.**
Generalises #4b's single-child guard: a quoted argument mixing literal text with
one or more command substitutions (`echo "count: $(ls)"`) now vets every inner
standalone and splices the **whole quoted arg** as one dynamic token, instead of
bailing on the multi-child string. A `$var`/`${…}`/arithmetic child fails the
whitelist and still bails (`"x$y$(ls)"`). Same one-directional safety: a gated
outer command's deny/ask still wildcard-fires on the dynamic token
(`find . "x$(echo -exec rm)"` prompts). No standalone note — folded here.

**Follow-on (#4c, done) — process substitution `<(cmd)`/`>(cmd)`.** A process
substitution always expands to a `/dev/fd/N` path — never a flag or subcommand —
so an argument-position `<(…)`/`>(…)` recurses its inner through
`walk_substitution_inner` (must approve standalone) and splices a **static
`/dev/fd` placeholder** (not dynamic — the expansion shape is known). So
`diff <(sort a) <(sort b)` approves while `diff <(rm x)` bails. Argument position
only; process substitution elsewhere still bails.

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

## #1 — tmp work as a `/trust` scope (Step A + Step B done)

**Today.** Two parallel notions of "is this mutation safe": the Bash walker is
path-agnostic (every non-`/dev/null` redirect bails, `rm` is `ask` and `rm -f`
denies), and `/trust` is path-aware but only for ACP file-edit kinds
(edit/write/create/delete/move). tmp scratch — Claude writing a command's output
to `/tmp/x`, reading it, removing it — is the common case neither covers without
a hand-written `Bash(...)` allow.

**Framing.** tmp auto-approval *is* `/trust` run on tmp; the only policy
difference is the recoverability backing. A repo's `/trust` leans on git (undo
via `git checkout`); tmp has no git, so its safety comes from "ephemeral by
convention" for writes and from "we created it this session" for deletes. So this
is not a new subsystem — it is `/trust` with one extra recoverability branch,
plus a second *producer* of mutation-effects (Bash, alongside the existing ACP
tool calls). It is the one item in this note that crosses out of the walker.

### Architecture: producer / policy split

The walker must **not** know about tmp, git, or scope. Split the two concerns:

- **Walker = pure effect extractor.** It returns `(ok, effects)` where
  `effects` is an *ordered* list of `{kind, path}` for the file-mutating leaves it
  can pin to a **concrete literal** (#3 resolution applies): a redirect target →
  `write`, an `rm` arg → `delete`, `touch`/`mkdir` → `create`. A path it cannot
  pin (dynamic `$x`, glob) bails rather than emitting an effect, so the command
  prompts (over-prompt-only preserved). `ok`
  carries every *non-file* verdict exactly as today — eval/source, exec-hijack env
  prefix, non-allowlisted command, etc. still bail structurally. Redirects and
  `rm` move *out* of the structural bail into `effects`. Approve the command iff
  `ok AND every effect clears`.
- **Policy consumer = `TrustSafety.safe_for_kind`** — the same oracle
  `_check_trust` already calls for ACP tool calls, now fed by two producers (one
  effect from a tool call, N effects from a Bash command). `is_under_tmp`,
  git-recoverability, and the session ledger all live here, in one place. No
  parallel "is this path safe" logic in the walker.

### Recoverability policy (the one new branch in `safe_for_kind`)

| kind | repo scope (git-backed) | tmp scope |
|---|---|---|
| write / create | new file, or tracked + clean | **safe** — clobbering tmp scratch is not loss of work |
| delete | tracked + clean | **only if created this session** — git can't restore it, so we must *know* it was Claude's own scratch |

Still gated, for every tmp effect, by the existing `/trust` safety properties:
symlink realpath also under tmp, strictly *under* a tmp root (never the root
itself, no `..`), and TOCTOU re-stat. **Temp root** = strictly under `/tmp`
(→`/private/tmp`) or `$TMPDIR` (macOS `/var/folders/…/T`), resolved once via
`vim.uv.os_tmpdir()` + realpath.

**"Created this session"** has two tiers:
- *Intra-command* (no state): the effects list is ordered, so
  `cmd > /tmp/x; rm /tmp/x` shows `create(/tmp/x)` before `delete(/tmp/x)` in one
  list → the consumer clears the delete. Covers the dominant "write a file and rm
  it in the same call" case with zero session state.
- *Cross-command* (session ledger): a `rm /tmp/x` in a *later* command needs a
  per-session set of paths created, fed by approved `create`/`write` effects from
  **both** Bash and ACP. This is the only new mutable state and the only place a
  stale entry could mislead.

### Activation and gates

- tmp **writes**: active `/trust tmp` scope. A `tmp` keyword for `/trust` is sugar
  over the literal-path scope that already exists, resolving to *all* roots (incl.
  mac's `$TMPDIR`, which a literal `/tmp` glob misses).
- tmp **deletes**: active `/trust tmp` **and** `Config.permissions.tmp_cleanup`
  (default `true`). Step B's intra-command correlation bounds a delete to a file
  the *same command* just created under tmp.
- **`rm -f`/`--force` always rejects** — no tmp carve. `should_auto_reject` runs
  before the approve walk and rejects on rm's structured force-deny gate
  unconditionally; force is unrecoverable, so it never auto-approves even for a
  tmp path. (Earlier this flag carried a path-aware deny-suppression carve; that
  was dropped in favour of the simpler always-reject rule.)
- **Startup activation**: `Config.permissions.trust_tmp` (default `true`) activates
  the `/trust tmp` scope at session start so tmp scratch is trusted out of the box,
  gated by `auto_approve_trust_scope`. `SessionManager:_apply_default_trust` (called
  from both `new_session` and `load_acp_session` once the session id is set) sets
  the scope silently — no chat message — and pushes it to the headers state. A
  scope the user set this session is left untouched. (Simpler than the originally
  planned general `startup_commands` list — only tmp trust was needed.)

### Why it's sound (invariant held)

The walker change only reclassifies redirect/`rm` leaves from "bail" to "emit an
effect"; an effect that doesn't clear still bails. A dynamic path never clears —
it bails (`walk_redirected`/`redirect_write_dest` return nil; the `rm` branch
returns false on a dynamic operand), never laundered through a sentinel `<dynamic>`
token. Deny/ask gates on the *command* are untouched (`rm -f`/`--force` rejects
outright, no tmp carve). So the surface only ever *adds* approvals for concrete
tmp paths under an active opt-in — never removes a deny/ask check. Composes with
#3: `d=/tmp/x; …; rm -r $d` resolves `$d`→`/tmp/x` before the effect is built.

### Accepted residual

A **dynamic filename component** keeps the whole pattern prompting:
`f=$(mktemp)`, `f=/tmp/x_$$.txt` (PID), `f=/tmp/x_$RANDOM` — `f` is not a known
literal, so `$f` stays dynamic at both the redirect target and the `rm` operand,
and both bail. This is not merely unimplemented: a dynamic path component can't
be proven to stay under tmp (a suffix expanding to `../../etc/x` escapes the
root), so prefix-based membership on the static `/tmp/...` head is **unsound**.
Auto-approving these would need stdout/runtime capture and is out of scope.

Note this is the common real shape — agents lean on `mktemp`/`$$` for scratch —
so the intra-command feature mostly fires for fully-literal paths
(`echo x > /tmp/test.sh; rm /tmp/test.sh`).

### Build order

- **Step A — writes (done).** Walker exposes effects via a new `evaluate` →
  `(ok, effects)` (the old `should_auto_approve` is kept as a boolean convenience
  = `ok and #effects==0`, so the pre-existing tests stay untouched). Redirect
  writes become `write` effects in `walk_redirected` (`redirect_write_dest` in
  `shell_parse.lua` returns the destination node, which `walk_redirected` resolves
  to a literal; dynamic/unmodelled still bails). `tmp` scope
  kind: `build_tmp_scope`/`is_under_tmp`/`tmp_roots` in `trust_safety.lua`,
  `safe_for_kind` short-circuits write/create on `args.tmp`; `_bash_effects_clear`
  in the manager resolves each effect's symlink pair and requires both endpoints
  strictly under a tmp root. `/trust tmp` keyword + picker entry. Non-destructive
  — no ledger, no flag, no deny override.
- **Step B — deletes (done, intra-command only).** A non-force `rm` not otherwise
  glob-allowed emits ordered `delete` effects per concrete operand in
  `walk_command` (dash-tokens are options rm never deletes a file for, so only
  `--`-trailing and plain words are operands; a dynamic operand bails like a
  dynamic redirect). The emission is a **fallback after the allow check** — an
  explicit `Bash(rm *)` allow approves rm cleanly with no effect (else the effect
  would withhold the user's own allow). `_bash_effects_clear` clears a `delete`
  only when an earlier `write`/`create` in the **same effects list** targeted the
  same resolved path (intra-command correlation) AND `Config.permissions.tmp_cleanup`
  is on. A function-definition body is walked with a throwaway effects list and is
  recorded as a safe call target only if it emits **no** effects — defining never
  runs the body, so an `rm` in it cannot be vetted by the policy layer (which sees
  only the outer command). `rm -f`/`--force` is rejected outright by
  `should_auto_reject` (no tmp carve). `tmp_cleanup` threaded into `WalkCtx` only.
  **Deferred:** the cross-command session ledger (Follow-up #2), and
  `touch`/`mkdir` → `create` effects (the dominant create source is a redirect
  `write`).

### Touches

`permission_rules.lua` (walk return contract → `(ok, effects)`,
threaded through `walk`/handlers; redirect + `rm` become effect emitters);
`trust_safety.lua` (`is_under_tmp`, tmp branch in `safe_for_kind`); `permission_
manager.lua` (clear Bash effects via `safe_for_kind`; own the session ledger;
feed it from approved create/write effects, Bash + ACP); `/trust` command parser
(`tmp` keyword); `session_manager.lua` (`_apply_default_trust`, called from
`new_session` + `load_acp_session`); `config_default.lua`
(`permissions.tmp_cleanup`, `permissions.trust_tmp`).

### Open decisions

1. **Session ledger now, or intra-command-only first?** Resolved: shipped
   intra-command-only (the cited case is intra-command; the ledger is the sole
   new state). Cross-command ledger → Follow-up #2.
2. **Effects-list refactor of the walker return contract** — confirmed worth it:
   Step B needs ordered create/delete anyway, so building it once is the
   non-duplicated path. (A write-only feature alone could have been a ~5-line
   inline predicate in `redirect_is_safe`; `rm` is what forces the list.)

### Follow-ups (found testing Step A/B — for another agent)

1. **Redirect-target resolution (Step A defect, done).** `redirect_write_target`
   returned raw `get_node_text`, pinning only a **bare literal** target. A quoted
   literal (`> "/tmp/x"`) and any variable (`> $f` / `> "$f"`) emitted a path that
   never passed tmp membership and never correlated with the `rm` operand (which
   *is* resolved, via `extract_args`), so `f=/tmp/x; echo >"$f"; rm "$f"` prompted
   even though the literal `echo >/tmp/x; rm /tmp/x` worked. **Fix shipped:**
   `shell_parse.redirect_write_target` is now `redirect_write_dest`, returning the
   destination **node** (parser knowledge); `walk_redirected` takes `known` and
   resolves the node to a literal — `resolved_var_name` + `known` lookup for a
   bound `$f`/`"$f"`, `literal_token` quote-strip for a quoted literal, bail on a
   dynamic/unbound target (previously emitted the raw `$f`). `walk_sequence` routes
   a `redirected_statement` straight to `walk_redirected` so the per-sequence env
   reaches it (the generic `walk` dispatcher passes `known=nil`, preserving the
   old bare-literal behaviour where no sequence env exists). Tests under
   "should_auto_approve with redirect" (quoted-literal, known-var bare/quoted,
   unbound-var bail, write-then-rm correlation).
2. **Cross-command session ledger (the dominant real-world gap).** Agents
   typically run the write and the `rm` as **separate** Bash tool calls, so the
   intra-command effects list never holds both — a later-command `rm /tmp/x`
   prompts. This is the deferred ledger from Open decision #1; it is what actually
   bites in practice, more than any single-command case. A per-session set of
   tmp paths created by approved `write`/`create` effects (Bash + ACP) clears a
   later `delete`. Sole new mutable state; stale-entry risk is the design care.
3. **`cd` tracking for relative effect paths.** `_bash_effects_clear` joins a
   relative effect path against `vim.uv.cwd()` (the editor cwd), and the walker
   ignores `cd`. A command has a knowable cwd: thread a current-dir through
   `walk_sequence` like #3's `known` (a literal `cd /abs` sets it; `cd $dynamic`,
   `cd -`, `pushd` clear it) and resolve relative effect paths against that. This
   is **not** `$PWD` expansion (env knowledge) — it is straight-line dataflow,
   same shape and soundness as #3. Rarely bites tmp (scratch paths are usually
   absolute), so lower priority than 1–2.

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
  `subtree_has_substitution`). Note: this is **not** a #4b tripwire — the bare
  `find $(echo x)` already prompts via find's `-exec` deny (verified), so #4b
  won't flip this boolean; post-#4b it prompts on the gate wildcard instead of
  the bail. The genuine #4b witness is a gate-free command (`cat "$(ls)"`).

**Optional follow-on (parked) — relax `is_safe_literal` for the quoted
channel.** Because quoting suppresses splitting and globbing, a quoted `"$base"`
could safely resolve values carrying whitespace or glob metacharacters
(`base="my dir/*.js"` → one literal arg). That needs a second "quote-safe"
binding tier in `known` / `update_known` (today an assignment with a space is
never recorded) consulted only in quoted position — more machinery for a rare
value shape. Defer until a real case appears; the change above needs none of it
(a plain path already passes `is_safe_literal`).

---

## #8 — resolve concatenation token shape (`$d/x`) — do first

**Today.** `head -40 $d/SKILL.md` prompts while `ls -la $d` approves — the only
difference is the token shape. `$d/SKILL.md` parses as a `concatenation`
(`variable_ref($d)` + `word(/SKILL.md)`). It carries no *command* substitution,
so it passes the `subtree_has_substitution` bail in `extract_args`
(`permission_rules.lua:~1048`), but `literal_token` → `pure_literal_token`
returns nil (a `$var` part isn't pure), so `extract_args` bails to a prompt.
`token_is_dynamic` also has no `concatenation` branch (returns false). A
concatenation bearing an expansion is therefore neither resolved nor recognised
as a token — it hard-bails, whereas the bare `$d` in the same position splices
as a dynamic token and approves.

**Change.** Handle a substitution-free `concatenation` as one token, resolving
statically when it can and falling to dynamic otherwise:

- **Static** — every part resolves to a safe literal: an inert `word`/`number`/
  `raw_string`, or a `$name`/`${name}` bound in `known` via `is_safe_literal`.
  Splice the joined literal as a **static** token (`base=/safe; head $base/x` →
  `head /safe/x`). This is the substrate #9 consumes.
- **Dynamic** — any part is an unbound var, glob, or `${…}` richer form: splice
  the whole concatenation's raw text as **one dynamic token** (`args_dynamic[i]
  = true`), exactly like a bare `$d`.
- **Bailed** — a part is a command/process substitution (`a$(b)c`): unchanged,
  caught by `subtree_has_substitution` in `extract_args` before these helpers.

Mechanically: add a `concatenation` branch to `token_is_dynamic` (true when a
named child is `variable_ref`/`simple_expansion`/`expansion`/
`arithmetic_expansion`/`glob_pattern`), and to `literal_token` (return raw node
text instead of nil when the concatenation is non-pure). The static-resolution
branch reads `known`, so it lives beside the `resolved_var_name` lookup in
`extract_args`' `child:named()` arm (or extend `resolved_var_name` to return a
joined literal for an all-resolvable concatenation).

**Why it's sound (over-prompt only; invariant held).**
- A concatenation bearing an unbound var/glob has the same post-expansion
  word-split surface as a bare `$d` — unquoted `$d/x` with `d="-e y"` splits to
  `-e` and `y/x`, so it *can* introduce a leading flag, which is precisely what
  the dynamic-token wildcard already models (satisfies any deny/ask option or
  positional at or after its index; never widens allow). Dynamic splicing is
  identical safety to the bare form, strictly fewer prompts.
- The static branch reads only `known` literals (populated solely from
  `is_safe_literal` pure-literal assignments) joined with inert literal words,
  so the result is a splitting-proof single word fed through the same gates.
  `base=--exec; find $base/x` still denies.

**Redirect site — no regression.** `walk_redirected` (`:1420`) calls
`literal_token(dest)` only when `not token_is_dynamic(dest)`. Making
`token_is_dynamic` true for a dynamic concatenation means a dynamic redirect
target (`cmd > $d/f`) skips `literal_token` → `target = nil` → bails, exactly as
today (a dynamic write target must bail). Confirm in tests.

**Touches.** `token_is_dynamic` + `literal_token` in `shell_parse.lua`; the
`else` arm of `extract_args` in `permission_rules.lua` (`~1044`) picks up the
dynamic token automatically. Tally mirror: `command_known_safe`/`tally_sequence`
reuse both helpers, so token shape is automatic; the `known`-based static branch
needs the tally arg extractor to thread `known` the same way — confirm parity.

**Tests** (`permission_rules.test.lua`):
- `head -40 $d/SKILL.md` → **approve** (empty `read_only` gate, dynamic token).
- `ls -la $d` → **approve** (regression guard — bare dynamic, unchanged).
- `find . $d/x` → **prompt** (dynamic wildcard fires find's `-exec`/`-delete`
  deny/ask — the case #9 recovers).
- `base=/safe; head $base/x` → **approve** (static resolution).
- `base=--exec; find $base/x` → **prompt/deny** (static resolution through the
  gate; symmetry with `f=--exec; find $f`).
- `head $d/*.js` → **approve**; `rm $d/*.js` → **reject** (glob part → dynamic).
- `cat a$(b)c` → **prompt** (command-sub concatenation stays bailed).
- `cmd > $d/f` → **prompt** (dynamic redirect target still bails).

---

## #9 — resolve a for-loop var over a literal list

**Today.** `walk_for` recurses into the body via the generic `walk(body)`, which
routes to `walk_sequence` with a fresh `known` — the loop var is never bound, so
a body reference is dynamic even when the list is entirely literal (`for d in
acp permissions provider-system; do find . $d/SKILL.md; done`). #8 lets that
body concatenation splice as a dynamic token, so a read-only command approves;
but a gated command (`find` with `-exec`/`-delete`) over-prompts, because the
dynamic wildcard cannot see that none of the three values is a flag. The value
is not truly dynamic — it provably ranges over a finite set of literals.

**Change.** When every for-list item is a safe-literal `word` (no substitution,
glob, or expansion; passes `is_safe_literal`) and the value count is within a
cap, walk the body **once per value** with `known` seeded `{ [loopvar] = value
}`; approve iff every pass approves. Otherwise fall back to the current single
dynamic walk (#8's floor). This reuses the entire single-value machinery — the
per-value walk is an ordinary sequence walk with one pre-bound literal.

- **Plumbing.** Give `walk_sequence` an optional seed-`known` parameter and call
  it directly from `walk_for` for the `do_group` body (bypassing the generic
  dispatcher, as `walk_redirected` is already special-cased inside
  `walk_sequence`). `update_known` still runs per body statement, so a body that
  rebinds the loop var (`d=$(…)`) drops the seed exactly as its rebinding rules
  dictate.
- **Product cap.** Nested literal loops multiply (`for a … do for b …`) — cap
  the total body-walk count and fall back to the dynamic walk on overflow (the
  safe direction).

**Why it's sound (over-prompt only; invariant held).**
- Each iteration binds the loop var to exactly one list element — a for-list
  literal word is one iteration value with no re-splitting, and `is_safe_literal`
  rules out IFS/glob, so the seeded `known[var]` is a genuine splitting-proof
  single word, identical to a #3 pure-literal assignment.
- Every value is fed through the *same* gates via an ordinary body walk.
  `is_safe_literal` admits flags (`-delete` matches its charset), so `for d in
  acp -delete; do find . $d` binds `d=-delete` on one pass and rejects. Approval
  requires *all* values to pass, so a single dangerous value blocks the loop.
- A non-literal list item (substitution/glob/expansion) or cap overflow falls
  back to the dynamic walk — never widens beyond #8.

**Depends on #8.** The body concatenation must resolve for the per-value binding
to matter; #8's static branch consumes the seeded `known`.

**Touches.** `walk_for` + `walk_sequence` (seed param) in `permission_rules.lua`;
the tally mirror `tally_for`/`tally_sequence` (`:2098`, `:2192`) must mirror the
per-value walk or highlights diverge from decisions.

**Tests** (`permission_rules.test.lua`):
- `for d in acp permissions provider-system; do find . $d/SKILL.md; done` →
  **approve** (all values resolve to positional paths).
- `for d in acp -delete; do find . $d; done` → **reject** (one value trips
  find's deny).
- `for d in acp permissions; do head $d/SKILL.md; done` → **approve** (guards the
  layering — also passes via #8 alone).
- `for f in $(ls); do find . $f; done` → **prompt** (non-literal list → dynamic
  fallback; #4's behaviour, regression guard).
- nested `for a in x y; do for b in p q; do …` beyond cap → **fallback** (prompt
  when the body is gated).

---

## #2 — walk into script *files*

Moved to its own note: [perm-walk-into-scripts.md](perm-walk-into-scripts.md).
It folds in the in-block create-then-run case (`echo "ls" > f.sh; zsh f.sh`)
that a `Bash(...)` allow can't express, and supersedes the parked framing here.

---

## Cleanup — strip plan-number tags from durable artifacts (do last)

The `#3`/`#4`/`#4b`/`#5`/`#6`/`#7`/`#8`/`#9` tags in this plan leaked into durable code
and skill prose, where they index *this ephemeral note* and go stale the moment
it is deleted. Once the features above are settled, strip every tag from:

- `permission_rules.lua` comments and `permission_rules.test.lua` block names.
- The permissions skill prose (`SKILL.md`, `references/parsing.md`, including the
  `#4b` breadcrumb in the arg-token-text table).

Keep the self-describing text; reword inline shorthand (`#3's known` → `the
per-sequence constant environment`). Commit linkage is git blame's job, not a
comment's. Do **not** promote this plan into the skill to keep the tags alive —
code must not reference skills.
