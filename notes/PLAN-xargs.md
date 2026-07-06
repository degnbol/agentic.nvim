# Plan: `xargs` as a transparent exec-wrapper

## Goal

Recurse the shell-command matcher into `xargs`'s inner command instead of
treating `xargs` as an opaque leaf that only matches the narrow `xargs ls`
carve-out. `xargs CMD ARGS…` should classify by what `CMD` actually does —
so `xargs grep`/`xargs cat` auto-approve, `xargs rm -rf` rejects, `xargs sort`
prompts — with no loss of soundness.

The recursion (not a widened carve-out) is chosen because only recursion can
inherit the **deny short-circuit** (`xargs rm -rf` → auto-reject) and emit
**trust-scope effects** (`xargs rm file` → delete effect). A `permissions.json`
allowlist could cover the read-only inners but neither of those, and the set of
safe inners is unbounded.

## Why `xargs` differs from `timeout`

`timeout N CMD…` spells its inner out literally; walking in classifies exactly
what runs. `xargs` **appends items read from stdin** (or `-a file`) to `CMD
ARGS…`, so the effective invocation is `CMD ARGS… <runtime-items>`. Those items
are invisible on the command line and behave like a dynamic token
(`CMD ARGS $items`). Naive recursion (copy the `timeout` path, classify bare
`CMD ARGS`) is unsound:

```
… | xargs sort      # items supply: -o /etc/passwd  → sort writes
… | xargs sed       # items supply: -i              → in-place edit
```

Bare `sort`/`sed` classify as `read_only`, so naive recursion would auto-approve
a write at the read-only tier.

## Behaviour: recurse into the literal inner, always append a dynamic token

Recurse into the literal inner and **unconditionally append a trailing dynamic
token** (`$__xargs_stdin`) to model the runtime-appended items. No feeder
detection: whether or not stdin actually feeds `xargs`, the appended token is
sound (it can only widen deny/ask, never widen allow — parsing.md § "Token
expansion").

Always-append is deliberately preferred over detecting the no-feeder case:

- It removes any dependence on "inherited stdin carries no adversarial bytes" —
  there is no accepted-unsoundness footnote.
- The read-only inners users actually pipe into (`grep`/`cat`/`rg`/`head`) have
  no write gate for the dynamic token to trip, so they still auto-approve.
- The only cost is over-prompting the **no-feeder standalone** form of an inner
  that *does* have a dynamic-option write gate (`xargs sort`, `xargs sed`).
  Standalone `xargs` runs the inner once with zero appended args (GNU) or zero
  times (BSD) — a near-non-existent workflow. Accepted for v1.

The dynamic token flows through the existing machinery unchanged: it wildcards
deny/ask (→ prompt) and never widens allow.

| Command | Recursed as | Outcome |
|---|---|---|
| `find … \| xargs grep foo` | `grep foo $dyn` | grep read_only, dyn no-op → **approve** |
| `find … \| xargs sort` | `sort $dyn` | dyn fires sort `-o` gate → **prompt** |
| `find … \| xargs rm -rf` | `rm -rf $dyn` | `-rf` concrete deny → **auto-reject** |
| `xargs grep foo` (no feeder) | `grep foo $dyn` | read_only, dyn no-op → **approve** |
| `xargs sort` (no feeder) | `sort $dyn` | dyn fires `-o` gate → **prompt** (v1 over-prompt) |
| `xargs sh -c '$x'` | dynamic `-c` body | → **prompt** (existing sh -c handling) |
| `xargs $CMD` | dynamic command name | → **prompt** (existing bail) |

Notes:
- GNU option permutation (an appended item acting as an option regardless of
  position) and `-I{}` mid-command replacement are both *over-covered* by the
  walker's "dynamic token satisfies any option/positional at or after its
  index" rule — worst case over-prompts.
- The dynamic token also costs trust-scope precision on `xargs rm file`: `rm
  $dyn` neither rejects (deny pass is concrete-only) nor emits a clearable
  delete effect, so it prompts. Accepted for v1; detecting the no-feeder case to
  restore literal-operand precision is deferred.

## Scope

- **`xargs` only.** `parallel` stays excluded — remote exec (`--sshlogin`), its
  own `{}` DSL, and per-input command construction genuinely worsen the inner.
- **`env`/`nohup`/`command`/`exec`** stay excluded (execution-hijack env / PATH
  mutation), unchanged.
- **No feeder detection in v1.** Always-append; the standalone over-prompt and
  the `xargs rm file` trust imprecision are the accepted costs.

## Implementation

All in `lua/agentic/utils/shell_parse.lua` unless noted.

### 1. `EXEC_WRAPPERS["xargs"]` spec — minimal common-flag table

Add an `xargs` entry. The option table is **not soundness-critical**: any
mis-slice (unrecognised option, wrong token count, value-vs-flag error) fails
*closed* — `skip_wrapper_operands` bails or the inner slices to a bogus token,
and either way the inner re-parses to a non-command → falls through → prompt. No
mis-slice can turn a dangerous inner into an auto-*approved* one, because the
inner is always re-parsed and matched on its own merits and the reject pass is
over-approximating. The table therefore only tunes over-prompts on legit
invocations — cover the flags that actually appear, add more when a real
invocation over-prompts:

- **value_opts** (value is the next token): `-I`, `-n`, `-P`, `-a`, `-L`,
  `--arg-file`, `--replace`, `--max-args`, `--max-procs`, `--max-lines`.
- **flag_opts**: `-0`, `-r`, `-t`, `--null`, `--no-run-if-empty`, `--verbose`.
- **attached**: `^%-I`, `^%-i`, `^%-n%d`, `^%-P%d`, `^%-L%d`, and the
  `^%-%-…=` long forms.
- No `positionals`, no `subcommand`, `writes = false` (effect-neutral like
  `timeout` — the inner's own class sets the tier).

BSD-specific flags (`-e`/`-l`) and the deprecated optional-arg replstr `-i`
without an argument are intentionally omitted — they fall through to a prompt.

### 2. Dyn append in `inner_source`

When the wrapper is `xargs`, compute the inner substring exactly as today
(`arg_nodes[inner_idx]` start → command node end) and return
`inner .. " $__xargs_stdin"` (origin unchanged, `writes = false`). For every
other wrapper the return is unchanged — **gate the append on
`cmd_name == "xargs"`** so `timeout`/`uv`/`stdbuf` paths are byte-for-byte
identical.

`$__xargs_stdin` is an unbound `$var` → re-parses as a dynamic token via the
normal walk. The obscure name avoids accidental resolution against an earlier
sequence binding.

**Three call sites inherit this with no per-caller edits** — the approve walk
(`walk_command`, ~1254), the tally/highlight walk (`tally_walk`, ~2013), and the
reject walk (`reject_walk`, ~2465) all route through `inner_source`. So deny
short-circuit, approval, and `allow_always` leaf harvesting share the change.

**Tally-walk origin is a non-issue** (verified): the sentinel is a dynamic *arg*
of the inner command, never a leaf and never a substitution, so it never enters
`body_ranges` or `subst_ranges` and never gets origin-translated. `xargs grep
foo` tallies clean (rememberable); `xargs sort` washes the whole leaf coarsely
(not rememberable) with no range pointing at the sentinel.

### 3. Remove the subsumed carve-out

`lua/agentic/permissions.json`: delete
`"xargs": { "read_only": [{ "positionals": ["ls"] }] }`. Now covered — `xargs
ls` → `ls $__xargs_stdin` → read_only → approve.

## Verification

No matcher coverage exists yet — `tests/unit/basic_test.lua` is a placeholder.
Add a real file (not a scratch script) driven by the existing `describe`/`it`
harness so `make validate` runs it. Scope to xargs only:

```lua
-- tests/unit/xargs_wrapper_test.lua
local R = require("agentic.utils.permission_rules")
assert(R.should_auto_approve("find . | xargs grep foo"))     -- read_only inner
assert(not R.should_auto_approve("find . | xargs sort"))     -- -o gate via dyn
assert(R.should_auto_reject("find . | xargs rm -rf"))        -- concrete deny
assert(R.should_auto_approve("xargs grep foo"))              -- always-dyn, no gate
assert(R.should_auto_approve("xargs ls"))                    -- carve-out subsumed
```

Then `make validate` (luals + selene + helptags + test). On failure read the
log with `tail`/`rg`, not the Read tool.

## Docs to update after implementation

- `lua/agentic/utils/shell_parse.lua` — the `EXEC_WRAPPERS` docstring
  (currently lists `xargs`/`parallel` as *deliberately excluded*); rewrite to
  explain `xargs` is now transparent with an always-appended dynamic token, and
  only `parallel` stays out.
- `.claude/skills/permissions/references/parsing.md` — note `xargs` under the
  transparent-prefix mechanics (recurse into the literal inner, always append a
  trailing dynamic token modelling the runtime stdin items).
- `.claude/skills/permissions/SKILL.md` — update the wrapper mention if `xargs`
  appears there.

## Residual / accepted (v1)

- Standalone `xargs` on a gated inner (`xargs sort`, `xargs sed`) over-prompts —
  the always-dyn cost. Feeder detection to fix it is deferred.
- `xargs rm file` trust-scope imprecision: `rm $dyn` prompts instead of emitting
  a clearable delete effect. Deferred with feeder detection.
- Bare `xargs` (utility defaults to `echo`) → empty inner → falls through →
  prompt. Minor over-prompt.
- Behaviour change: `xargs rm -rf` currently prompts, will auto-reject (concrete
  deny short-circuit). Consistent with the deny model.
