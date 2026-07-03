# Plan: resolve known-literal vars before the safety check

## Problem

A shell command that interpolates a statically-knowable variable into a
position the shell later **re-parses as source** currently falls through to a
permission prompt, even when the fully-expanded command would auto-approve.

Trigger case (real, observed):

```zsh
cmd='cd /some/long/path && npm install --save-dev typescript && npm run build && npm test'
for i in 1 2 3; do
  /usr/bin/time -p sh -c "printf '%s' '$cmd' | shfmt -ln bash -i 2 -ci >/dev/null" 2>&1 | rg real
done
```

The `sh -c` body is a double-quoted string containing `$cmd`. `token_is_dynamic`
(`shell_parse.lua:337`) flags it, so `inner_source` (`shell_parse.lua:706`)
returns nil at the `args_dynamic[i+1]` guard (`:711`/`:728`) and the walk never
looks inside. The whole `sh -c "…"` leaf is recorded unapproved
(`permission_rules.lua:2330`) → prompt + coarse whole-leaf highlight.

But `cmd` has exactly one clear literal assignment, so the expanded body is
statically knowable:

```
printf '%s' 'cd /some/long/path && npm install --save-dev typescript && npm run build && npm test' | shfmt -ln bash -i 2 -ci >/dev/null
```

`printf` is read-only, `shfmt` is allow-listed (`.claude/settings.json:23`,
`~/.claude/settings.json:22`), `>/dev/null` is a safe redirect. It **would
auto-approve**. The only thing blocking it is that we never resolve `$cmd` and
re-check.

## The general pattern and its soundness boundary

This is the point that was debated, so it is pinned here as the spec.

The general principle is sound and *is* general:

> Resolve a statically-known literal at its point of use, then re-run the safety
> analysis on the expanded form.

What is **not** general is *how the expanded form is analysed* — that depends on
the position semantics, and getting this wrong is unsound:

| Position | What the shell does with the value | Sound re-check |
| --- | --- | --- |
| **Reparse context** — a shell `-c` body (`sh`/`bash`/`zsh`/`dash -c`), `eval` | The inner shell parses the post-expansion bytes as **source**: operators, quotes, substitutions all re-interpreted. | **Re-parse as shell.** Multi-word / metacharacter values are fine — the re-parse reproduces exactly what the inner shell does. |
| **Single-word quoted** — `"$f"`, `'…'` | Exactly one literal word; no split, no glob. | Token substitution. **Already implemented** (`resolved_var_name` + `is_safe_literal`). |
| **Bare / unquoted arg** — `find $f` | Value is **word-split** on IFS and glob-expanded into *argument words*. Operators/quotes/`$()` are **NOT** re-interpreted. | Split on IFS + glob-expand, inject the results as **literal argument tokens**. A re-parse here is UNSOUND. |

The unsoundness of a naive "re-parse everywhere" is decisive:

```zsh
x='foo; rm bar'; echo $x     # shell: word-splits → echo gets args "foo;" "rm" "bar"; rm does NOT run
                             # insert+reparse: `echo foo; rm bar` → rm RUNS. WRONG.
```

So the existing `is_safe_literal` single-word guard (`permission_rules.lua:597`)
and the `resolved_var_name` whole-arg guard (`:615`) are **correct and must
stay** — they are the sound subset for the *bare-arg / token-substitution*
mechanism, where token-subst == word-split == reparse only holds for a
metacharacter-free single word.

**v1 scope = the reparse-context row only** (`-c` bodies). It is:

- the case that triggered this,
- the soundest (re-parse *is* what the inner shell does — no need to reimplement
  IFS word-splitting + globbing),
- common (interpolated `sh -c "…"` / `bash -c "…"` command strings).

The bare-arg multi-word/glob row is **deferred** (see § Deferred).

### Why re-parse of a `-c` body is byte-exact

The outer shell, expanding `$cmd` inside the double-quoted `-c` argument, inserts
the value bytes **verbatim** (no added quoting, no recursive substitution — one
expansion pass). So rebuilding the body by replacing the `$cmd` node's span with
its raw literal value reproduces exactly the bytes `sh -c` receives; parsing
those with the zsh grammar models the inner shell. This holds even when the
value itself contains `$(…)` or `&&`: the inner shell genuinely re-parses those,
and so does our walk (fail-closed on anything it can't resolve). A value like
`$HOME/x` re-parses to a live `$HOME` expansion → dynamic → prompt, which is
correct (the inner shell expands `$HOME` from an environment we don't model).

## Existing infrastructure

| Primitive | Location | Role |
| --- | --- | --- |
| `inner_source` | `shell_parse.lua:706` | Resolves the `-c` body / wrapper inner; bails on dynamic body at `:711`/`:728`. The v1 hook point. |
| `SHELL_C_COMMANDS` | `shell_parse.lua:545` | `zsh`/`bash`/`sh`/`dash` — the reparse-context command set. |
| `pure_literal_token` | `shell_parse.lua` (~202) | Strict literal extraction; returns nil if the value bears any expansion/substitution. Already computed in `update_known`. |
| `update_known` | `permission_rules.lua:887` | Builds the `known` map. Records `lit` only when `is_safe_literal` (single-word). The multi-word value is computed then discarded. |
| decision `-c` recursion | `permission_rules.lua:1253-1269` | `walk_command` re-parses + `walk`s the inner. |
| tally `-c` recursion | `permission_rules.lua:2012-2037` | `command_known_safe` re-parses + `tally_walk`s the inner. |
| `walk_command` / `command_known_safe` | `:1154` / `:1960` | Both already receive `known` in scope. |
| `should_auto_reject` | `:2528+` | Separate deny pass; walks via the same sequence machinery that builds `known`. |

## Approach

### 1. Store the raw literal value

`update_known` already computes `lit = pure_literal_token(value)` before the
`is_safe_literal` gate. Currently a multi-word `lit` is dropped. We need it
retained for the reparse path **without** loosening the single-word constraint
that token-substitution relies on.

Two options:

- **(A) Richer `known` values** — store `{ lit = string, safe = boolean }`.
  Token-substitution sites (`resolved_var_name`/`literal_token`/
  `resolved_concatenation`, reads at `:655`, `:1039`, `:1477`, `:648`) use the
  entry only when `.safe`; the `-c` reparse path uses `.lit` unconditionally.
  Threads no new params (the `known` map already flows everywhere), but touches
  every read site.
- **(B) Parallel `known_raw` map** — a second map recording every
  `pure_literal_token` value (multi-word included), threaded only into the `-c`
  resolution path. Leaves the sound-critical substitution reads untouched; adds a
  param to `inner_source` and the two recursion callers.

**Recommend (B)** — it keeps the risky, soundness-critical token-substitution
logic byte-for-byte unchanged and confines the new behaviour to one new path.
`inner_source` is also called by `extract_commands` (`shell_parse.lua:909`),
which has no `known` — (B) makes the param optional there (nil ⇒ current
behaviour), which is natural.

### 2. Reconstruct the expanded body

New helper (in `shell_parse.lua`, beside `inner_source`): given the body node
(`arg_nodes[i+1]`) and `known_raw`, walk its children and build the expanded
string:

- `string_content` (and literal word bytes) → verbatim.
- `simple_expansion` / `expansion` of a **plain** `$var` / `${var}` →
  `known_raw[var]` if present, else **bail** (return nil → current dynamic
  behaviour).
- `command_substitution` / `process_substitution` / fancy expansion
  (`${v:-x}`, `${#v}`, `$v[1]`, …) in the body → **bail**.

Restrict v1 to `string` (double-quoted) bodies; `raw_string` (single-quoted) is
already handled statically, and other shapes bail (unchanged). If every
expansion resolves, `inner_source` returns the expanded string as `inner` (nil
origin — see § Highlight).

### 3. Walk / tally the expanded inner

No change to the recursion at `permission_rules.lua:1253-1269` and
`:2012-2037` beyond passing `known_raw` down to `inner_source`. The reparse is
walked with a **fresh** `known` (matching today's recursion): the sub-shell does
not inherit our binding — the reference was already expanded by the outer shell,
so any *remaining* `$var` in the reparsed body is an inner-shell expansion we
correctly treat as dynamic.

Wire `known_raw` consistently into all three consumers so the decision, the deny
short-circuit (`should_auto_reject`), and the highlight agree: decision-`walk`,
`should_auto_reject`'s walk, and the tally `command_known_safe`.

## Highlight (byte-shift) — coarse in v1

Expansion changes byte offsets (`$cmd` = 4 bytes → ~90), so tally ranges
computed on the expanded body cannot be translated back to buffer coordinates.
v1 does **not** attempt range mapping: `inner_source` returns a nil origin on the
expanded path, so an unapproved expanded leaf falls back to the coarse
whole-leaf highlight (exactly what double-quoted bodies already do,
`permission_rules.lua:2011`). The **decision** is precise; only the highlight is
coarse. Precise sub-ranges are a later refinement, not v1.

## Deferred

- **Bare-arg multi-word / glob resolution** (the third row of the table).
  Requires faithfully modelling IFS word-splitting **and** globbing to inject the
  value as literal argument tokens — a re-parse is unsound there (the
  `echo 'foo; rm bar'` example). Separate change, separate risk.
- **Precise highlight ranges** through an expansion (needs an offset map from
  expanded-body coordinates back to the pre-expansion source).
- **`eval <string>`** as a reparse context. Currently a hard bail
  (`CODE_TAKING_BUILTINS`); could be resolved the same way when its argument is a
  fully-known literal. Lower value, more caution warranted.

## Test plan

Add to `permission_rules.test.lua` (mirrors the existing `sh -c` / `zsh -c`
cases around `:2271-2312`):

- **Approves** `cmd='…safe…'; sh -c "printf '%s' '$cmd' | shfmt …"` when the
  expanded leaves are all allow-listed.
- **Approves** the full trigger command (for-loop + `/usr/bin/time -p` wrapper +
  interpolated `sh -c`).
- **Prompts** when the expanded body contains an unruled/unsafe leaf
  (`cmd='rm -rf /'; sh -c "$cmd"` must NOT approve — re-parse sees `rm -rf /`).
- **Prompts / bails** when the interpolated var is not a known literal
  (`sh -c "$undefined"`, `cmd=$(foo); sh -c "$cmd"`).
- **Soundness regression** — the deferred bare-arg case must still fail closed:
  `x='foo; rm bar'; echo $x` must NOT approve `rm` (guards against someone
  wiring the reparse path into bare-arg position by mistake).
- **Nesting** still bounded by `NESTED_MAX_DEPTH`
  (`cmd='zsh -c "rg foo"'; sh -c "$cmd"`).

Run: `make validate`.

## Risks

- **Wiring the reparse expansion into a non-reparse context** would be unsound
  (the `echo` example). Mitigation: the expansion lives *inside* `inner_source`,
  which is only entered for `SHELL_C_COMMANDS` `-c` bodies and exec-wrappers —
  never bare-arg position. The soundness regression test pins this.
- **`known_raw` staleness across rebinding** — must follow `update_known`'s
  existing per-command invalidation (a later non-literal assignment or an
  un-enumerable mutation clears the name). Reuse the same clear logic; do not add
  a second lifetime model.
- **Value bearing a live inner expansion** (`$HOME/x`) re-parses to a dynamic
  token → prompt. Correct (fail-closed), not a regression.
