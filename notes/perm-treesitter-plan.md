# Treesitter-based compound-command auto-approval (consolidated plan)

> Supersedes `perm-treesitter-rework-proposal.md` (layer-1/layer-2 framing,
> fail-closed) and `agentic-treesitter-permissions.md` (walker spec, loop +
> substitution support, permissions.json audit). Node-type facts below are the
> ones verified against the installed zsh parser on 2026-06-06 — including two
> corrections to the source plans (see § Corrections).

## Goal

Replace the hand-rolled regex shell tokeniser in
`lua/agentic/utils/permission_rules.lua` with a walker over the **zsh
treesitter parse tree**. Structural shell constructs (substitution, pipelines,
redirects, quoting, loops) are recognised by a real grammar instead of
approximated by character-by-character state machines.

This is a security-critical rewrite. The governing discipline is **fail-closed**:
anything not explicitly proven safe falls through to a permission prompt. The
only error that matters is unsoundness (approving something unsafe);
incompleteness only costs a prompt.

## Decisions (settled)

- **zsh-only.** bash has no installed parser and the grammar is less
  maintained; both claude-agent-acp and opencode run commands in `$SHELL=zsh`.
  No bash↔zsh parity work, no normalisation shim.
- **zsh parser is a hard dependency** of the advanced security system. No
  hand-rolled fallback splitter — the old tokeniser is deleted, not kept. If
  the parser is absent or the tree has errors, return `false` (prompt). This is
  the only "fail-closed" branch; there is no second code path.
- **Full feature scope, phased for review surface.** Preserving the current
  system is not a goal; the extra capabilities treesitter unlocks
  (assignment-position substitution, loops) are a bonus. They land in a separate
  phase only because the substitution-safety reasoning is subtle and deserves
  focused review — not for backwards compatibility.

## Amendment (2026-06-12): Policy C — structured command matcher

The original plan kept the glob matcher verbatim and only changed *decomposition*
(see § "What is deleted vs kept"). That leaves flag-writers hidden in a single
token uncatchable, because the matcher still globs extracted text: `sort -uo out`
(non-leading `-o` in a cluster), `sort --out=x` (GNU abbreviation), `sort -oFILE`
(glued arg) all evade a `Bash(sort * -o *)` glob. The original Phase 0 response
(add deny globs for `sort`/`tee`; document `sed`/`awk` residuals) inherits the
same leak — those globs are unsound against clustering and abbreviation.

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
is occasional over-prompting (incompleteness-safe). This dissolves the Phase 0
sort/sed/awk/tee flag-write items — they become structured rules, not glob
patches.

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
["o","output"]}`, soundly, because the structured layer expands the cluster. The
glob layer carries conveniences; the structured layer is the cluster-proof
backstop.

The glob matcher *shrinks* under the walker: it loses `split_command`,
`mask_quoted_operators`, `has_unsafe_redirect`, `strip_devnull_redirects`
(structure is the walker's job now) down to `glob_to_lua_pattern` +
`matches_any_pattern` over the leaf command text the walker hands it.

### Only option-gating rules get structured

The cluster-leak exists *only* for a rule that gates on a specific flag of a
specific command. It does not affect, and these all stay glob strings (including
in bundled `permissions.json`):

- bare-command allows (`grep *`, `cat *`) — no flag to leak
- subcommand rules (`git diff *`, `aws * describe-*`) — representable, no leak
- generic/positional globs (`* --help`, `pdftotext *.pdf -`, `* list*`) — fine

The structured layer is just the **flag-writers**:

- **Migrated** (already deny/ask globs, lifted for cluster-soundness):
  `sed -i`, `find -exec/-okdir/-delete`, `ruff --fix`, `stylua --replace`,
  `mlr -I`, `date -s`, `yq -i`, `gh api -X/-f/-F/--input`.
- **New** deny-on-write-flag rules for commands kept in read_only/safe_write
  for their benign case:
  - `sort` — `-o`/`--output`
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
  "subcommand": "api",             // optional; first non-option token (see below)
  "options": ["o", "output"] }     // flag ids: short letters and/or long names
```

Option matching is the sound over-approximation above (short-cluster letters +
long-name + long-prefix candidates from every literal token). `subcommand`
detection skips the command's arg-taking global options so an option's argument
isn't mistaken for the subcommand — a small per-command list (git: `-C`, `-c`,
`--git-dir`, `--work-tree`; gh/aws: none). This is faithful to the `git *diff*`
/ `git -C … diff` intent and *stricter* than the glob: today `git *diff*` wrongly
matches `git -C diff push` (path literally `diff`) and auto-approves the push;
the structured form resolves subcommand=push and prompts.

### Migration

Lift the ~20–30 option-gated entries into the `structured` section; leave every
other bundled entry as a glob string; drop the now-dead pipeline-globs
(`grep * | head *`, `mount | grep *`, `* list *| grep *`) — the walker checks
each pipe segment independently. No 360-entry rewrite, no lossy conversion of
settings.json. (The Phase 0 `find -okdir` glob patch is superseded by the
structured `find` rule, which catches the positions the glob missed.)

**Injected-sublanguage descent.** The config's `queries/zsh/injections.scm`
injects awk/jq/sql/python/etc. into command-argument strings, and
`get_string_parser(cmd, "zsh")` + `parse(true)` resolves those subtrees
(verified: `awk 'BEGIN{system(...)}'` → `languages in tree: zsh, awk`). So the
walker can descend into an injected sub-language and apply sub-language safety
rules: awk's `system()`/`print >`/pipe-to-command → deny (closes the awk
residual the original plan documented); `sqlite3 '<sql>'` → SELECT-only. This is
a Phase-1+ capability, scoped per sub-language.

**Remaining residuals (genuinely uncatchable, document):**
- `sed` `e`/`s///e` (exec) and `w`/`W`/`s///w` (write) — no sed parser/injection,
  so the script body is opaque. Same tier as `awk -f scriptfile`.
- Dynamic expansion (`sort $FLAG out` where `$FLAG=-o`) — pre-existing limit,
  already tolerated for any `$var`/glob/`~`.

**Consequences for the sections below:** § "What is deleted vs kept" mostly
stands — the glob matcher functions (`glob_to_lua_pattern`, `matches_any_pattern`,
`extract_bash_patterns`, `load_patterns`, …) are **kept** as the glob layer, and
the structural helpers (`split_command`, `mask_quoted_operators`,
`has_unsafe_redirect`, `strip_devnull_redirects`, `is_inert_segment`) are still
deleted (the walker replaces them). The structured matcher is **new code added
beside** the glob matcher, not a rewrite of it; the glob bucket format is not
replaced. The Phase 0 § sort/tee/awk/curl items defer into the Phase 1 structured
layer; only the `find -okdir` deny (a live exec hole, glob-expressible,
BSD-present) shipped as a data patch under the current matcher. The sed analysis
below stands (recommend document), now joined by the awk-via-injection upgrade.

## Scope boundary

`should_auto_approve(command: string) → boolean` is the single behavioural entry
point, called once from `ui/permission_manager.lua:296` on a cold, human-speed
path. The layer-2 pattern API (`get_*_patterns`, `matches_any_pattern`) and the
four `permissions.json` buckets are unchanged — treesitter changes only **how
the command string is decomposed** and **how non-simple structure is refused**.
`get_additional_directories`, `_always_cache`, and trust-scope are untouched.

## What is deleted vs kept

**Deleted** (structural layer, replaced by the walk):
`split_command`, `mask_quoted_operators`, `has_unsafe_redirect`,
`strip_devnull_redirects`, `is_inert_segment`, and the env-prefix logic inside
`strip_wrapper_prefixes`.

**Kept verbatim** (matcher layer — fed node-extracted text instead of
regex-split segments): `glob_to_lua_pattern`, `extract_bash_patterns`,
`patterns_from_strings`, `load_patterns`, `read_json`, `settings_paths`,
mtime caching, `get_{read_only,safe_write,allow,deny,ask}_patterns`,
`get_additional_directories`, `SAFE_ENV_NAMES`, `is_safe_env_name`,
`is_data_var_name`, `SYSTEM_BIN_DIRS`, `strip_command_path`, `invalidate_cache`,
`matches_any_pattern`.

Note `matches_any_pattern` currently calls the deleted `strip_devnull_redirects`
and `mask_quoted_operators` (`permission_rules.lua:588,595`). After the rewrite
the walker hands it substitution-free, redirect-free leaf text, so those two
calls are removed from the matcher and their work is gone (handled structurally).

## Core: `should_auto_approve(command)`

```
1. allow = get_allow_patterns(); if #allow == 0 → return false
2. ok, root = pcall(get_string_parser(command, "zsh"); parse)
   - parser unavailable OR pcall fails → return false   (fail-closed)
3. if root:has_error() → return false                   (truncated/malformed/misparse)
4. return walk(root)  -- true only if EVERY node is proven safe
```

## The walker — explicit whitelist, reject-by-default

`walk(node)` dispatches on `node:type()`. Any type **not** whitelisted →
`false`. Iterate **named children only**; ignore anonymous separators uniformly
(`;`, `&&`, `||`, `|`, `&`, newline) — never dispatch an anonymous token through
the whitelist (a backgrounded `rm x & ls` has `&` as an anonymous `program`
child; dispatching it would over-reject every backgrounded command). Each
`command` sibling is still walked independently.

### Container nodes (recurse; all children must pass)

`program`, `list`, `pipeline`, `do_group`, **`variable_assignments`**.

> `variable_assignments` (plural) is the container for `a=1 b=2`
> (`program(variable_assignments(variable_assignment, variable_assignment))`).
> It is **not** the `variable_assignment` arm below — missing it regresses the
> current `a=1 b=2 → true` approve-case. (Correction to the older plan.)

### `command`

1. **Subtree substitution scan first** (see § Substitution-anywhere). Bail on
   any unguarded `command_substitution` / backtick / `process_substitution`
   anywhere in the subtree.
2. **Command-name child** must be a literal: `word`, `string`, `raw_string`, or
   a `concatenation` of literals only. Bail if the name is
   `command_substitution`, `expansion`, `simple_expansion`, `variable_ref`,
   `arithmetic_expansion`, or a `concatenation` containing any of these
   (`$(echo rm) -rf /`, `ec$(echo ho) hi`, `$((1+2))` all bail — dynamic command
   word).
3. **Leading `variable_assignment` children** (env prefixes, `LC_ALL=C grep x`):
   reuse the hijacker check (`is_safe_env_name`/`is_data_var_name`); uppercase
   hijacker (`PATH=`, `LD_PRELOAD=`, `BASH_ENV=`) → bail. The value must be a
   literal — a command-prefix assignment whose value is a substitution
   (`foo=$(rm x) ls` runs `rm x` as a side effect) bails via the subtree scan.
   Do **not** recurse into command-prefix assignment values the way the
   statement-level `variable_assignment` arm does.
4. After the scan passes, extract the command text up to (excluding) any trailing
   redirect, run `strip_command_path`, match against `allow`; reject on
   `deny`/`ask`. The extracted text is substitution-free, so extraction is
   unambiguous and `mask_quoted_operators` is unneeded (top-level operators are
   sibling nodes, never inside a `command`).

### `redirected_statement`

> The redirect parent node is `redirected_statement`; `file_redirect` is its
> `redirect`-field child and never a direct recurse target. Whitelisting only
> `file_redirect` (as the newer plan did) regresses every redirect case
> (`grep foo 2>/dev/null`, `ls 2>&1`). (Correction to the newer plan.)

- Recurse the `command` child (must pass).
- Each `file_redirect`, classify by target:
  - target subtree contains a substitution (`cat > $(echo out)`) → bail first.
  - `/dev/null` → safe.
  - fd duplication (`2>&1`, `>&N`, `N>&M`) → safe.
  - any other target (a `word`/`string` filename) → bail (file write).
  - `&>`/`&>>` combined redirects → bail (file writes).
- `heredoc_redirect`, `herestring_redirect` → bail (input-only, not modelled;
  also covers `cat <<< $(rm x)`). Conservative; could be allowed later.

### `variable_assignment` (statement-level, inert)

- literal value (`word`/`string`/`raw_string`/number) → safe.
- value is `command_substitution` → recurse (§ Substitution safety).
- value is `array` → recurse into elements (`arr=($(rm x))` must prompt;
  `arr=(a b c)` safe).
- value contains `process_substitution`/arithmetic we don't model → bail.

### `command_substitution` (statement-level value / array element ONLY)

- Recurse `walk` over its inner `command`/`redirected_statement`/`pipeline`/
  `list` — every inner command must be auto-approvable, and a redirect inside
  (`f=$(foo > bar)`) is caught by the same `file_redirect` classification.
- Reached in any other position (arg, command name, command-prefix assignment,
  for-list, redirect target, here-string) → the parent's subtree scan bails
  before recursing here.

### Explicitly rejected (bail; never add to the recurse list)

`subshell`, `process_substitution`, `if_statement`, `case_statement`,
`function_definition` (unmodelled control flow); `negated_command` (`! rm x`),
`compound_statement` (`{ rm x; }`), `test_command` (`[[ -f x ]]`) — these
*contain* a `command` child, so a maintainer might be tempted to recurse them;
that would let `! rm x` approve if `rm` were allowed, inverting intent. Plus the
catch-all default. `declaration_command` (`export FOO=bar`) is not whitelisted →
bails → prompt (harmless).

**Code-taking builtins** (`eval`, `source`, `.`) are not node types but `command`
nodes whose command-name is one of these; the argument is shell code the matcher
cannot see through. Guard in the `command` arm: command-name `eval`/`source`/`.`
(after `strip_command_path`) → bail. They are **not** transparent wrappers — never
strip and re-check them. `command`/`exec` need no such guard: they match no allow
pattern, so the default reject already prompts (and stripping them would be
unsound — `exec` replaces the shell process, and bare `exec > out` mutates the
current shell's fds before any redirect classifier could see the target).

## Substitution-anywhere scan (completeness rule)

A substitution can be buried at any depth in an argument, not just as a direct
child. The probe confirmed all of these hide one where "check direct children"
misses it: `echo "$(rm -rf x)"` (under `string`), `echo a$(whoami)b` (under
`concatenation`), `ec$(echo ho) hi` (concatenation in command-name position),
`foo=$(rm x) ls` (in command-prefix `variable_assignment`), `cat > $(echo out)`
(in a `file_redirect` target), `arr=($(rm x))` (in an `array` value).

Per `command` (and per redirect target, per loop list): scan the whole subtree
for substitution-bearing node types and bail unless every occurrence is in the
single accepted position (a statement-level / assignment-value recursion target
per § Substitution safety). A helper `subtree_has_unguarded_substitution(node)`
makes this one reusable check. Never reason about "direct children".

## Substitution safety — assignment position ONLY

**Allow command substitution as a `variable_assignment` value (or array
element); reject it in command-argument, command-name, for-list, and
redirect-target positions.**

Argument-position substitution **launders dangerous tokens past the deny/ask
layer** — the mechanism that makes broad allow patterns tolerable. A literal
`find . -exec rm {}` matches the `Bash(find * -exec *)` deny pattern and prompts;
`find $(echo '-exec rm')` does not — the matcher sees only `$(...)`, but at
runtime `find` receives `-exec rm` and executes the deletion. The substitution
converts a denied command into an approved one. Not unique to `find`: any
read-only-looking command with a write flag (`sort -o $(echo out) in`) is a
vector. So no allow entry is immune, and arg-position substitution must bail.

Assignment position is safe: `f=$(X)` puts X's output into a variable; this
statement runs only the assignment plus X as a side effect (the recursion guards
X — `f=$(rm x)` prompts because `rm` is not allowed; `f=$(foo > bar)` prompts
because the inner `file_redirect` fires). The dangerous expansion is deferred to
a later, separately-evaluated use site (`find $f`), which inherits the
**pre-existing** limitation that text-based deny patterns can't see through any
dynamic expansion (variables, globs, `~`) — already tolerated today. Allowing
the assignment doesn't widen that; it only avoids a spurious prompt on the inert
assignment.

## Loop support

`for_statement`, `while_statement`, `until_statement` join the whitelist.

- `for_statement` list items must be literal/glob. Run the subtree-substitution
  scan over the list: a substitution anywhere (`for f in $(ls)`,
  `for f in a $(ls) b`) bails — its output becomes loop values that flow into
  body args (the same arg-position laundering, deferred through the loop var). A
  `glob_pattern` list (`for f in *.txt`) is allowed; the `$f` body expansion is
  opaque, same as any `$var`, so no new hole.
- `do_group` body: recurse `walk` over every command — bounded by allow patterns
  (`rm "$f"` only approves if `rm *` is allowed, which it is not).
- `while`/`until` condition is a `command` (`read l`) → recurse, must be
  auto-approvable.
- `if_statement`/`case_statement` stay rejected — natural follow-up, same
  machinery.

## Corrections to the source plans (verified by spike)

1. `a=1 b=2` parses as `variable_assignments` (plural container), **not** two
   `variable_assignment` siblings — the older plan's claim is wrong; the type
   must be whitelisted or the approve-case regresses.
2. The redirect parent is `redirected_statement`, not a bare `file_redirect` —
   the newer plan's whitelist would regress all redirects.
3. `$((1+2))` is `command(command_name(arithmetic_expansion))`, which bails
   (dynamic command name) — the older plan's "fixes `$((1+2))` to approve" claim
   is false. It prompts; it matches no allow pattern anyway, so no regression.
4. **Wrapper-prefix commands** parse with the real command as an *argument*
   (`time grep foo` → command name `time`, arg `grep`), so the matcher sees
   `time grep foo`, not `grep foo` — identical to current behaviour (the deleted
   splitter couldn't see through them either). `stdbuf` parity is preserved by the
   kept `strip_wrapper_prefixes` (its env-prefix logic deleted, the `stdbuf`
   branch unchanged). Generalising the unwrap so the *wrapped* command's safety
   governs (`time`/`timeout`/`stdbuf`, and explicitly **not** `command`/`exec`) is
   a separate capability, not part of this migration — see
   `notes/perm-wrapper-command-auto-approve.md`. The `eval`/`source`/`.` bail is a
   soundness property of the walker itself and stays here (§ Explicitly rejected).

## Phase 0 — permissions.json defence-in-depth audit (data only)

Live, currently-exploitable holes, independent of the parser rework. Pure data,
shippable separately/first:

- `sort -o out in` / `sort --output=FILE` writes a file (`sort *` in
  `read_only:91`, no carve-out) → add `Bash(sort * -o *)` and
  `Bash(sort * --output*)` to **deny**.
- `tee out` writes by design (`tee *` in `read_only:318`, no carve-out) → add a
  deny carve-out. (The older plan's list missed this; its own "re-scan for
  flag-writers" instruction would catch it — so do the full re-scan, don't just
  patch the named cases.)
- `awk 'BEGIN{system("rm -rf /")}'` executes arbitrary code (`awk *` in
  `read_only:180`) → add `Bash(awk *system*)` to **deny**. Residual `awk -f
  scriptfile` is out of reach but writing the script is itself gated — document,
  don't chase.
- **`sed` `e` command/flag** executes shell (`sed` in `read_only:179`, only
  `-i` carved out). Two positionally-distinct forms: the `s///e` flag
  (`sed 's/x/y/e'`, trailing in the flag run after the last delimiter) and the
  `e` command (`sed 'e cmd'`, `sed '1e cmd'`, after an optional address,
  mid-script). They have **different anchors**, so no single glob catches both:
  a trailing-`e` pattern misses the `e` command, and a loose `Bash(sed *e*)`
  false-positives on any `e` in a word (`sed 's/dependencies//'`). Flag order
  (`ge` vs `eg`) and a following filename further break anchoring. **Decision
  needed:** (a) demote `sed` out of `read_only` (costs the common
  `sed 's/a/b/' file` approval), or (b) accept the `e`-command residual as a
  documented limitation (same tier as `awk -f scriptfile`). An anchored glob
  carve-out (c) is not cleanly expressible — do not rely on it. Recommend (b).

## Phasing

- **Phase 0** — permissions.json audit above. Data only, no logic, no parser
  dependency. Can ship first/independently.
- **Phase 1** — structural swap: walker with the whitelist above **minus**
  assignment-substitution recursion and loops (reject all control flow and all
  substitution). Every existing approve/prompt corpus case must pass unchanged;
  delete the five replaced helpers; convert helper-level tests to behavioural.
  This is where the bulk of validation against the corpus lives.
- **Phase 2** — add assignment-position `command_substitution` recursion and
  `for`/`while`/`until` loops. Isolated here so the subtle substitution-safety
  trust-widening gets a focused review.

## Testing

The 116-case corpus in `permission_rules.test.lua` is the contract and the
regression oracle. Helper-level describe-blocks for deleted functions
(`split_command:?`, `mask_quoted_operators`, `has_unsafe_redirect`,
`strip_devnull_redirects`, `is_inert_segment`) get rewritten as end-to-end
`should_auto_approve` assertions before deletion. The `should_auto_approve`,
`should_auto_approve with redirect`, and `config permissions` blocks are
behavioural and must pass unchanged. Tests for kept matcher functions
(`matches_any_pattern`, `strip_command_path`, `strip_wrapper_prefixes`,
`glob_to_lua_pattern`, `extract_bash_patterns`) survive as-is.

New cases:

- **Phase 1 negatives:** `$(echo rm) -rf /`, `$(rm -rf /)`,
  `grep $(cat list) f`, `echo "$(rm -rf x)"`, `echo a$(whoami)b`,
  `ec$(echo ho) hi`, `cat > $(echo out)`, `cat <<< $(rm x)`,
  `cat foo &> out`, `cat foo &>> out`, `"rm" -rf /` (quoted name → `rm`),
  `! rm x`, `{ rm x; }`, `[[ -f x ]] && rm y`, `( rm -rf x )`, `cat <(ls)`,
  `eval rm -rf /`, `source script`, `. script` (code-taking builtins → bail),
  `exec rm -rf /`, `exec > out` (no transparent-wrapper strip → prompt),
  truncated `rm -rf / |` (`has_error`), `for …` / `while …` (rejected in P1).
- **Phase 1 positives (parity):** `a=1 b=2`, `arr=(a b c)`,
  `f=path/to/file; ls "$f"`, `echo '$(foo)'` (raw_string, no subst),
  `ls # rm -rf /` (comment), all current redirect approve-cases.
- **Phase 2 positives:** `f=$(echo hi)`, `for f in *.txt; do cat "$f"; done`.
- **Phase 2 negatives:** `foo=$(rm x) ls`, `arr=($(rm x))`, `f=$(rm x)`,
  `f=$(foo > bar)`, `find $(echo '-exec rm')`, `for f in $(ls); do …`.
- **Phase 0:** `sort -o out in`, `tee out`, `awk 'BEGIN{system("rm -rf /")}'`
  (and the sed decision's chosen behaviour) all prompt.
- **Parser guard:** force `get_string_parser` unavailable → `should_auto_approve`
  returns `false` (not error). Confirm `zsh.so` resolves in the mini.test
  headless env.

Pin tests against the installed grammar; document the regenerate/upgrade
dependency in a comment (node names can drift across tree-sitter-zsh versions).

Run `make validate` after each step.

## Risks

- **zsh grammar maturity** — builtins parse as generic commands, `~` in test
  brackets misparses. None compromise safety: misparse → `has_error` → bail;
  unmodelled-but-clean node → not whitelisted → bail. Worth sampling real agent
  commands to gauge how often clean commands degrade to a prompt.
- **Pathological input** — cap input length (refuse over N KB) to avoid a slow
  parse on a very long generated command. Cold path, short strings → sub-ms
  normally.
- **Blast radius** — large rewrite of a security module. Mitigated by the
  untouched matcher layer, the behavioural corpus as contract, and the phasing.

## Docs to update on completion

`CLAUDE.md` client-side auto-approval bullet #2 and `acp/AGENTS.md` § "Compound
Bash commands" — the split-on-operators description becomes a tree-walk +
hard-zsh-parser-dependency description. README permission section: note the zsh
parser requirement.
