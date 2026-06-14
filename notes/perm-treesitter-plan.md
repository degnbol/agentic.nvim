# Treesitter-based compound-command auto-approval — Phase 1b + Phase 2

## Status

Phase 0 (permissions.json defence-in-depth) and Phase 1a (zsh treesitter walker
swap) have shipped:

- Walker at `lua/agentic/utils/permission_rules.lua:485-766` (commit `19710f8`)
- `awk *system*` deny (commit `4c81e35`), `find * -okdir *` deny (`0092dbc`)
- Five replaced helpers deleted (`split_command`, `mask_quoted_operators`,
  `has_unsafe_redirect`, `strip_devnull_redirects`, `is_inert_segment`)
- `glob_to_lua_pattern`: `*` → `.*` (`permission_rules.lua:72`)
- Phase-1a corpus at `permission_rules.test.lua:1020-1175`
- `sed e`/`s///e` residual accepted as a documented limitation (see § Remaining
  residuals)

Remaining: Phase 1b (structured option-matcher beside the glob matcher) and
Phase 2 (assignment-position substitution + loops). Two items (`sort -o`/
`--output`, `tee` carve-out) are not in Phase 0 because the analysis below
shows globs are unsound against option clustering — they land in Phase 1b's
structured matcher instead.

The governing discipline remains **fail-closed**: anything not explicitly
proven safe falls through to a permission prompt.

## Phase 1b — structured command matcher

The walker hands the glob matcher one leaf command at a time, but the matcher
itself is still glob-based — so flag-writers hidden in a single token are
uncatchable: `sort -uo out` (non-leading `-o` in a cluster), `sort --out=x`
(GNU abbreviation), `sort -oFILE` (glued arg) all evade a `Bash(sort * -o *)`
glob. Deny globs for `sort` and `tee` would inherit the same leak — globs are
unsound against clustering and abbreviation regardless of how clean the input
tokens are.

**Decision: replace the glob matcher with a structured matcher over the
tokenised `command` node.** Tree-sitter gives clean token boundaries (through
quoting, whitespace, operators) that the glob cannot; it does *not* give getopt
semantics (it won't expand `-uo` → `-u -o` or bind `-o`'s argument). We don't
need the semantics — only flag *presence*, and over-approximating presence is
**sound for deny/prompt**:

- single-dash token `-uo` → candidate flags = letter-set `{u,o}` **and**
  long-name `uo` (find-style single-dash long flags like `-okdir`, `-exec`).
- double-dash token `--output=x` → long-name `output`, prefix-matched (catches
  GNU abbreviations `--out`).
- quote-stripped string/raw_string tokens are candidates too (`sort "-o" out`).
- a rule `{cmd: "sort", deny_options: ["o", "output"]}` matches if **any**
  candidate hits.

Adding spurious candidates (glued-arg chars, the wrong cluster interpretation)
can only make *more* deny rules fire → more prompts. It can never miss a real
deny flag. So `-o`/`-oFILE`/`-uo`/`--output`/`--out=` are all caught; the cost
is occasional over-prompting (incompleteness-safe).

### Architecture: two layers, not a merge

The user's own patterns (`~/.claude/settings.json`, `.claude/settings.json`,
`Config.permissions.*`) are Claude's glob `Bash(...)` format, shared with the
Claude TUI — they cannot move to a structured schema. So the glob matcher
**stays**, and the structured matcher is **added beside** it. They compose as
defense-in-depth, evaluated per walker-extracted command:

```
approve  iff  (glob_allow OR structured_allow)
        AND NOT (glob_deny OR structured_deny OR glob_ask OR structured_ask)
```

Allow is union (either layer authorises); deny/ask is OR (either layer vetoes).
The payoff: a command the glob layer over-allows (`Bash(sort *)` matching
`sort -uo out`) is still vetoed by the structured deny `{cmd: sort, options:
["o","output"]}`, soundly, because the structured layer expands the cluster.
The glob layer carries conveniences; the structured layer is the cluster-proof
backstop.

### Only option-gating rules get structured

The cluster-leak exists *only* for a rule that gates on a specific flag of a
specific command. It does not affect, and these all stay glob strings
(including in bundled `permissions.json`):

- bare-command allows (`grep *`, `cat *`) — no flag to leak
- subcommand rules (`git diff *`, `aws * describe-*`) — representable, no leak
- generic/positional globs (`* --help`, `pdftotext *.pdf -`, `* list*`) — fine

The structured layer is just the **flag-writers**:

- **To lift** from existing deny/ask globs for cluster-soundness:
  `sed -i`, `find -exec/-okdir/-delete`, `ruff --fix`, `stylua --replace`,
  `mlr -I`, `date -s`, `yq -i`, `gh api -X/-f/-F/--input`.
- **New** deny-on-write-flag rules for commands kept in read_only/safe_write
  for their benign case:
  - `sort` — `-o`/`--output`
  - `tee` — no carve-out today; structured rule denies the all write case
    by default and we add an opt-in
  - `curl` — `-o/-O/--output/--remote-name` (already deny) plus the uncarved
    write/exfil flags `-K/--config` (loads `-o` from a file), `-T/--upload-file`,
    `-D/--dump-header`, `--output-dir`, `--trace-ascii`
  - `http` (httpie) — `-d/--download`, `-o/--output`
  - `awk` — `system`/`print >`/pipe-to-command, via injection descent

~20–30 rules, not 360. `permissions.json` becomes **mixed**: most entries stay
glob strings, a small `structured` section carries these.

### Structured schema

```jsonc
{ "cmd": "sort",                   // command name, after strip_command_path
  "subcommand": "api",             // optional; first non-option token
  "options": ["o", "output"],      // short letters and/or long names
  "positionals": ["*.pdf"] }       // optional; glob-matched positional args
```

Option matching is the sound over-approximation above (short-cluster letters +
long-name + long-prefix candidates from every literal token). `subcommand`
detection skips the command's arg-taking global options so an option's argument
isn't mistaken for the subcommand — a small per-command list (git: `-C`, `-c`,
`--git-dir`, `--work-tree`; gh/aws: none). This is faithful to the `git *diff*`
/ `git -C … diff` intent and *stricter* than the glob: today `git *diff*`
wrongly matches `git -C diff push` (path literally `diff`) and auto-approves
the push; the structured form resolves subcommand=push and prompts.

**Glob is allowed on `positionals` and flag *values*, but never on `options`.**
A positional has no cluster ambiguity, so a glob over the walker-extracted
token is precise (clean boundaries, no quoting/operator confusion) —
`positionals: ["*.pdf"]` faithfully expresses `pdftotext *.pdf -`, and a
positional glob can pin a subcommand a whole-command glob can't. But `options`
must stay structured id-matching: a glob on a flag (`-o*`) would reabsorb the
cluster leak this layer exists to close (`-uo` would no longer expand to
`{u, o}`). So the schema is *available* for any field, glob-*capable* on
positionals/values only, and **used per rule only where it adds soundness** —
bare-command and positional globs that have nothing to gate stay plain glob
strings in `permissions.json`.

### Migration

Lift the ~20–30 option-gated entries into a new `structured` section in
`permissions.json`; leave every other bundled entry as a glob string; drop the
now-dead pipeline-globs (`grep * | head *`, `mount | grep *`,
`* list *| grep *`) — the walker already checks each pipe segment
independently. No 360-entry rewrite, no lossy conversion of settings.json.

The currently-shipped `Bash(find * -okdir *)` glob deny is superseded by the
structured `find` rule, which catches the positions the glob missed (clusters,
mid-args). Keep the glob entry until the structured rule lands; remove in the
same change.

**Injected-sublanguage descent (opportunistic only — not a backstop).** The
config's `queries/zsh/injections.scm` injects awk/jq/sql/python/etc. into
command-argument strings, and `get_string_parser(cmd, "zsh")` + `parse(true)`
resolves those subtrees *when that query is on the runtimepath*. The injection
is **not** intrinsic to the zsh parser: in a clean env (`-u NONE`, only
`~/.local/share/nvim/site` on rtp) `awk 'BEGIN{system(...)}'` resolves as
`zsh` only — the awk subtree appears solely when the config dir (which owns
`queries/zsh/injections.scm`) is on rtp. agentic.nvim is a
submodule of that config so the query is present in situ, but other consumers
of the plugin — or a config change — can remove it. So injection descent is a
**best-effort enrichment** (awk's `system()`/`print >`/pipe-to-command → deny;
`sqlite3 '<sql>'` → SELECT-only), scoped per sub-language, but it must never
be the *only* thing guarding a sub-language hole. The parser-independent
backstop is the shipped `Bash(awk *system*)` glob deny — keep it regardless of
injection descent; do not delete it in favour of the walker.

### Remaining residuals (genuinely uncatchable, document)

- `sed` `e`/`s///e` (exec) and `w`/`W`/`s///w` (write) — no sed
  parser/injection, so the script body is opaque. Same tier as
  `awk -f scriptfile`. Keep `sed` in `read_only` and document the residual:
  a glob carve-out is unsound at both the `Bash(...)` line level and inside
  the structured `positional` field (GNU sed needs no space after `e`,
  accepts a bare `e`, accepts an address prefix, and `s///e` allows any
  delimiter and any flag order). Precise patterns leak; the only bypass-free
  glob (`*e*`) denies most real sed use.
- Dynamic expansion (`sort $FLAG out` where `$FLAG=-o`) — pre-existing limit,
  already tolerated for any `$var`/glob/`~`.

### Phase 1b tests

- `sort -uo out` (short cluster), `sort --out=x` (GNU abbreviation),
  `sort -oFILE` (glued arg) → all deny via
  `{cmd: sort, options: ["o","output"]}`.
- `git -C diff push` → subcommand resolves to `push`, not the `-C` arg `diff`
  → prompt.
- positional-glob allow (`pdftotext *.pdf -`) → approve.
- `tee out` → deny via structured `tee` rule.
- `curl -K config.txt` → deny (config-file write/exfil flag).

## Phase 2 — assignment-position substitution and loops

Isolated as a separate phase so the substitution-safety trust-widening gets a
focused review.

### Substitution safety — assignment position ONLY

**Allow command substitution as a `variable_assignment` value (or array
element); reject it in command-argument, command-name, for-list, and
redirect-target positions.**

Argument-position substitution **launders dangerous tokens past the deny/ask
layer** — the mechanism that makes broad allow patterns tolerable. A literal
`find . -exec rm {}` matches the `Bash(find * -exec *)` deny pattern and
prompts; `find $(echo '-exec rm')` does not — the matcher sees only `$(...)`,
but at runtime `find` receives `-exec rm` and executes the deletion. The
substitution converts a denied command into an approved one. Not unique to
`find`: any read-only-looking command with a write flag (`sort -o $(echo out)
in`) is a vector. So no allow entry is immune, and arg-position substitution
must continue to bail.

Assignment position is safe: `f=$(X)` puts X's output into a variable; this
statement runs only the assignment plus X as a side effect (the recursion
guards X — `f=$(rm x)` prompts because `rm` is not allowed; `f=$(foo > bar)`
prompts because the inner `file_redirect` fires). The dangerous expansion is
deferred to a later, separately-evaluated use site (`find $f`), which inherits
the **pre-existing** limitation that text-based deny patterns can't see
through any dynamic expansion (variables, globs, `~`) — already tolerated
today. Allowing the assignment doesn't widen that; it only avoids a spurious
prompt on the inert assignment.

Implementation in the walker:

- Whitelist `command_substitution` as a recurse target **only** when its parent
  is a statement-level `variable_assignment` value or an `array` element.
  Recurse `walk` over its inner `command`/`redirected_statement`/`pipeline`/
  `list` — every inner command must be auto-approvable, and a redirect inside
  (`f=$(foo > bar)`) is caught by the same `file_redirect` classification.
- Reached in any other position (arg, command name, command-prefix assignment,
  for-list, redirect target, here-string) → the existing subtree scan still
  bails before recursing here.

### Loop support

`for_statement`, `while_statement`, `until_statement` join the whitelist.

- `for_statement` list items must be literal/glob. Run the subtree-substitution
  scan over the list: a substitution anywhere (`for f in $(ls)`,
  `for f in a $(ls) b`) bails — its output becomes loop values that flow into
  body args (the same arg-position laundering, deferred through the loop var).
  A `glob_pattern` list (`for f in *.txt`) is allowed; the `$f` body expansion
  is opaque, same as any `$var`, so no new hole.
- `do_group` body: recurse `walk` over every command — bounded by allow
  patterns (`rm "$f"` only approves if `rm *` is allowed, which it is not).
- `while`/`until` condition is a `command` (`read l`) → recurse, must be
  auto-approvable.
- `if_statement`/`case_statement` stay rejected — natural follow-up, same
  machinery.

### Phase 2 tests

- **Positives:** `f=$(echo hi)`, `for f in *.txt; do cat "$f"; done`.
- **Negatives:** `foo=$(rm x) ls`, `arr=($(rm x))`, `f=$(rm x)`,
  `f=$(foo > bar)`, `find $(echo '-exec rm')`, `for f in $(ls); do …`.

## Risks

- **zsh grammar maturity** — builtins parse as generic commands, `~` in test
  brackets misparses. None compromise safety: misparse → `has_error` → bail;
  unmodelled-but-clean node → not whitelisted → bail. Worth sampling real
  agent commands to gauge how often clean commands degrade to a prompt.
  - On a parser upgrade, re-verify that `comment` never attaches as a child of
    a `command` node. In the pinned grammar comments only attach to containers
    (`program`, `pipeline`) or to an `array`, all of which skip them, so
    `walk_command`'s arg loop never folds a comment into a matched leaf. If a
    future version nests `comment` under `command`, mirror the container
    walk's comment-skip into the arg loop — incompleteness-safe today (an
    inert comment can't change the command name or evade an anchored deny),
    so this is a drift hardening, not a live bug.
- **Pathological input** — input length cap (refuse over 64 KB, fail-closed →
  prompt) already enforced; keep when adding the structured matcher.
- **Blast radius (1b)** — adding a *new* matcher layer is a new attack
  surface with its own soundness argument (cluster expansion, subcommand
  detection skipping arg-taking globals). Land 1b separately from 2 for
  focused review.

## Docs to update on completion

- `CLAUDE.md` client-side auto-approval bullet #2 and `acp/AGENTS.md`
  § "Compound Bash commands" — add a paragraph on the structured matcher
  beside the glob matcher (Phase 1b), and on assignment-substitution + loop
  support (Phase 2).
- README permission section — note the zsh parser requirement (Phase 1a
  shipped; check whether the README already reflects this).

## Surface in the PR description (out of scope to fix here)

`Bash(env *)` in `read_only` auto-approves arbitrary commands as a side
effect (`env PATH=/tmp/evil sh -c …`) — `env` *as a command* is untouched
by this plan. The walker's env-prefix handling covers `LC_ALL=C grep x` (the
prefix form), not `env` invoked as a program. Adjacent to the env handling
this plan moves, so flag it. See `notes/perm-wrapper-command-auto-approve.md`.
