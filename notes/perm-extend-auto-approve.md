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

Build order: **#3, #4, #5** (preserve the invariant, no new config, broad
benefit) → **#1** (off by default, narrow) → **#2** (parked, see end).

**#5 is done** (`shell_c_body` / `parse_zsh` + the `-c` branch in `walk_command`,
mirrored in `command_known_safe`; tests under "inline shell -c body"). Remaining:
#3, #4, #1, #2.

---

## #4 — generalise command-substitution recursion

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

**Stays bailed** (output becomes a control surface the dynamic-token machinery
can't guard):
- **command-name** `$(echo rm) x` — output *is* the binary (`DYNAMIC_NAME_TYPES`).
- **redirect target** `cat > $(echo f)` — output *is* a write path
  (`redirect_is_safe`).

**Touches.** `walk_command`, `walk_for`, `literal_token` (signal "recurse" for a
`command_substitution` arg child rather than returning nil). Mirror in
`command_known_safe` / `tally_for` for the highlight pass.

---

## #3 — flow-sensitive literal propagation

**Today.** A `$var` is always dynamic — `f=/safe/dir; find $f` bails because the
dynamic `$f` flips `has_dynamic`, which wildcard-fires find's `-exec` deny gate.
Documented residual ("benign dynamic value over-prompts").

**Change.** Thread a **constant environment** through `walk`, scoped to one
straight-line statement sequence (a `list`, `do_group`, or branch body). Walk
each sequence left-to-right; on a pure-literal assignment record `known[var]=L`;
when resolving a `$var` token in `walk_command`, substitute the literal and mark
the token static. The resolved literal is fed through the **same** gate
evaluation (so `f=--exec; find $f` still hits find's deny).

**Soundness rests entirely on the invalidation set.** Drop `var` to dynamic on:
1. reassignment to a non-literal, or any reassignment not provably the same
   literal;
2. assignment to `var` nested inside an intervening control-flow sibling
   (`d=/safe; if c; then d=/danger; fi; git $d` — `$d` must stay dynamic) — needs
   a recursive "collect assignment targets in this subtree" scan;
3. the non-`var=…` assignment vectors: `read d`, `for d in …` (loop var),
   `${d:=…}` / `${d:-…}` default-expansion, `unset d`.

No cross-sequence propagation (a nested block's bindings do not leak to its
parent). `$HOME`/`$PWD`-style expansion is a **separate later step** (env
knowledge, not dataflow) — out of scope here.

**Why it's the real value.** Commands with no deny/ask gates (`rg`, `cat`)
already approve with dynamic args; #3 only changes outcomes for commands where a
dynamic positional currently wildcard-fires a gate (`find`, `git`, `sort`).

**Touches.** New env threaded through `walk` and its handlers; `walk_assignment`
(record), `walk_command` (resolve at token extraction), new
collect-assignment-targets helper. Container handlers create/scope the env.

---

## #5 — walk the body of an inline `zsh -c '…'`

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
Inner function definitions still bail without the #2 function-walker — but
inline `-c` bodies are overwhelmingly simple pipelines, so this fires without
that dependency.

**Touches.** `walk_command` (shell-`-c` branch, before the structured ask so the
`c` gate doesn't pre-empt it); `ctx.depth` guard; mirror in `command_known_safe`.

---

## #1 — `rm` of Claude's own scratch (`scratch_rm`)

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

## #2 — walk into script *files* (parked)

`zsh run-tests.zsh`: read the file, parse, walk. **Sound, not unsafe** — in this
architecture auto-approval fires synchronously with no human-wait window and ACP
runs tool calls sequentially, so the TOCTOU gap between the plugin reading the
file and the shell reading it has no writer in it.

**Blocked on bail rate, not safety.** The walker has no `function_definition`
handler (`walk` dispatch, lines ~1223–1257), so the first `foo(){…}` fails
closed; real scripts also bail on `source`, on a harness command not in the
allowlist (`nvim --headless`, `make`, `pytest`), or on any write redirect. The
scripts that pass are the trivial all-allowlisted ones — already covered by a
one-line `Bash(zsh run-tests.zsh)` allow in `.claude/settings.json`.

To make #2 beat that one-liner, first build **function-definition walking**:
walk each `foo(){…}` body, record it, and make a call to a locally-defined `foo`
recurse into the recorded body instead of bailing. That is the real work;
reading the file is the easy part on top. Keep the walker language-agnostic
enough (the body-walk in #5 and a future file-read share the "parse a body,
recurse `walk`" shape) that a non-zsh extension needs no major refactor.

Revisit only when wanting general safe-script approval across many scripts.
