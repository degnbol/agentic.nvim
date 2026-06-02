# Plan: Treesitter-based compound-command permission parser

## Goal

Replace the hand-rolled regex shell tokeniser in
`lua/agentic/utils/permission_rules.lua` with a walker over the **zsh
treesitter parse tree**, so structural shell constructs (command
substitution, pipelines, redirects, quoting, loops) are recognised by a
real grammar instead of approximated by character-by-character state
machines.

This is a security-critical rewrite. The governing discipline throughout is
**fail-closed**: anything not explicitly proven safe must fall through to a
permission prompt.

New capabilities delivered:
1. `f=$(echo hi)` — command substitution in **assignment position only**
   (argument position is deliberately rejected — see § Substitution safety).
2. `for`/`while` loops with **literal/glob** lists and auto-approvable bodies
   (see § Loop support).
3. Fixes two existing false bails: `echo '$(foo)'` (literal `$(` in a single
   quote) and `$((1+2))` (arithmetic, not command substitution).

## Why zsh, not bash

There is no `bash.so` installed — only `site/parser/zsh.so`
(georgeharker/tree-sitter-zsh). The config already aliases bash→zsh for
rendering, and Claude's commands run in `$SHELL=zsh`. The plan targets the
`zsh` language directly. Confirmed available and parsing correctly via
headless probe (`vim.treesitter.get_string_parser(cmd, "zsh")`).

## Grammar grounding (verified by probe)

Representative trees from the installed zsh parser:

| Input | Relevant nodes |
| --- | --- |
| `ls -la /tmp` | `command` → `command_name(word)`, `word`, `word` |
| `f=$(echo hi)` | `variable_assignment(variable_name, =, command_substitution(command))` |
| `$(echo rm) -rf /` | `command` → `command_name(command_substitution …)` — command word is **generated** |
| `grep foo \| head` | `pipeline(command, \|, command)` |
| `a && b ; c` | `list(command, &&, command)`, `;`, `command` |
| `cat foo > evil` | `redirected_statement(command, file_redirect(>, word 'evil'))` |
| `cat foo 2>/dev/null` | `file_redirect(file_descriptor '2', >, word '/dev/null')` |
| `f=$(foo > bar)` | redirect is `file_redirect` **inside** the `command_substitution` |
| `grep $(cat list) file` | `command` → literal `command_name`, `command_substitution` arg |
| `for f in *.txt; do …; done` | `for_statement(for, simple_variable_name, in, glob_pattern, ;, do_group(do, …, done))` |
| `while read l; do …; done` | `while_statement(while, command, ;, do_group)` |
| `( rm -rf x )` | `subshell` |
| `cat <(ls)` | `process_substitution` |
| `cat <<EOF…` | `heredoc_redirect` |
| `cat <<<EOF` | `herestring_redirect` |
| `echo '$(foo)'` | `raw_string` — **no** `command_substitution` node |
| `$((1+2))` | `arithmetic_expansion` — **no** `command_substitution` node |
| `LC_ALL=C grep x` | `command(variable_assignment, command_name, word)` — prefix assignment is a **child of `command`** |
| `/usr/bin/grep foo` | `command_name(word '/usr/bin/grep')` — path is one `word` |
| `rm -rf / \|` (truncated) | `root:has_error() == true` |
| `echo "$(rm -rf x)"` | substitution is a child of a `string` node (not a direct arg child) |
| `echo a$(whoami)b` | substitution inside a `concatenation` arg |
| `ec$(echo ho) hi` | `concatenation` in **command-name** position |
| `foo=$(rm x) ls` | `command(variable_assignment(…command_substitution…), command_name 'ls')` — prefix-assignment subst |
| `cat > $(echo out)` | `file_redirect(>, command_substitution)` — substitution as redirect **target** |
| `cat <<< $(rm x)` | `herestring_redirect(<<<, command_substitution)` |
| `arr=($(ls))` | `variable_assignment(variable_name, =, array(command_substitution))` |
| `rm x & ls` | `program(command, & (anon), command)` — `&` is an anonymous child |
| `! rm x` | `negated_command(command)` |
| `{ rm x; }` | `compound_statement(command)` |
| `[[ -f x ]] && rm y` | `list(test_command, &&, command)` |

## Architecture

### What is REPLACED (the deleted bloat)

- `split_command` — operator/quote/newline tokeniser → tree walk
- `mask_quoted_operators` — parser knows quotes
- `has_unsafe_redirect` + `strip_devnull_redirects` → `file_redirect` node
  classification
- `is_inert_segment` — assignment is now `variable_assignment` node type
- Most of `strip_wrapper_prefixes` — env prefixes are `variable_assignment`
  children of a `command` node

### What is KEPT verbatim (the matching layer — untouched)

- `glob_to_lua_pattern`, `extract_bash_patterns`, `patterns_from_strings`
- `load_patterns`, `read_json`, `settings_paths`, mtime caching
- `get_{read_only,safe_write,allow,deny,ask}_patterns`
- `get_additional_directories`
- `SAFE_ENV_NAMES`, `is_safe_env_name`, `is_data_var_name`
- `SYSTEM_BIN_DIRS`, `strip_command_path`
- `invalidate_cache`

Treesitter replaces only the **structural** layer. Glob→pattern matching is
unchanged.

### New core: `should_auto_approve(command)`

```
1. allow = get_allow_patterns(); if #allow == 0 → return false
2. ok, root = pcall(parse with zsh parser)
   - parser unavailable OR pcall fails → return false   (fail-closed)
3. if root:has_error() → return false                    (truncated/malformed)
4. return walk(root)  -- recursive, true only if EVERY node is proven safe
```

`pcall` + parser-availability fallback preserves the module's current
**zero-hard-dependency** property: with no zsh parser it degrades to "always
prompt", never to "wrongly approve".

### The walker — explicit node whitelist, reject-by-default

`walk(node)` dispatches on `node:type()`. Any type **not** in the whitelist →
return false. This reject-by-default is the central safety property; the
temptation to handle only the happy path is the failure mode a parser invites.

Container/structural nodes (recurse into children, all must pass):
- `program`, `list`, `pipeline`, `do_group`
- anonymous separators (`;`, `&&`, `||`, `|`, `&`, newline) — ignored. **The
  walker iterates *named* children only and ignores anonymous nodes
  uniformly** — never dispatch anonymous tokens through the whitelist, or a
  backgrounded command (`rm x & ls`, where `&` is an anonymous `program` child)
  would hit the default-bail and over-reject every backgrounded command (a
  correctness regression). Each `command` sibling is still walked
  independently, so `rm x & ls` correctly requires `rm` to be allowed.

#### Substitution-anywhere scan (the central completeness rule)

Command substitution (and backticks / process substitution) can be **buried at
any depth** inside an argument, not just as a direct child. The probe confirms
all of these hide a substitution where a naive "check direct children" misses
it:

| Input | Where the substitution lives |
| --- | --- |
| `echo "$(rm -rf x)"` | child of a `string` node |
| `echo a$(whoami)b` | child of a `concatenation` node |
| `ec$(echo ho) hi` | `concatenation` in **command-name** position |
| `foo=$(rm x) ls` | `command_substitution` inside a command-**prefix** `variable_assignment` |
| `cat > $(echo out)` | `command_substitution` as a `file_redirect` **target** |
| `arr=($(rm x))` | `command_substitution` inside an `array` value |

The rule, applied per `command` (and per redirect target, per loop list): **scan
the entire subtree for substitution-bearing node types
(`command_substitution`, backtick `command_substitution`,
`process_substitution`) and bail unless every occurrence is in the single
accepted position — a statement-level or assignment-value recursion target per
§ Substitution safety.** Never reason about "direct children" — depth is the
trap a parser invites here. A helper `subtree_has_unguarded_substitution(node)`
makes this one reusable check.

`command` node:
- Inspect `command_name`'s child. Accept only literal forms: `word`,
  `string`, `raw_string`, or a `concatenation` **of literals only**. A
  `concatenation` containing a substitution (`ec$(echo ho)`) → **bail** (the
  subtree scan catches this).
  - If `command_name` is `command_substitution`, `expansion`,
    `arithmetic_expansion`, `variable_ref`, or `simple_expansion`
    → **bail** (command word is dynamic — `$(echo rm) -rf /`).
- Leading `variable_assignment` children (env prefixes): reuse the hijacker
  check (`is_safe_env_name` / `is_data_var_name`); an uppercase hijacker
  (`PATH=`, `LD_PRELOAD=`, `BASH_ENV=`) → bail. **The value must be a literal**
  — a command-prefix assignment whose value is a `command_substitution`
  (`foo=$(rm x) ls`) executes `rm x` as a side effect and → **bail** (the
  subtree scan catches it; do not treat command-prefix assignments like the
  statement-level assignment arm, which *is* allowed to recurse).
- Run the subtree-substitution scan over the whole `command` node → bail on any
  unguarded substitution. Only after that scan passes:
- Extract the command text up to (but excluding) any trailing redirect, run
  `strip_command_path`, match against `allow`; reject on `deny`/`ask`. Reuse
  the existing compiled-pattern matching, fed node-extracted text instead of
  regex-split segments. Because the scan already bailed on any substitution,
  the extracted text is substitution-free and the extraction is unambiguous.
  `mask_quoted_operators` is no longer needed: the matched text contains real
  quotes, the glob `*` still maps to the non-operator class, and any top-level
  operator is now a *sibling* node, never inside a `command`.

`redirected_statement`:
- Recurse into the `command` child (must pass).
- For each `file_redirect`: classify by target.
  - **First**: if the target subtree contains a substitution
    (`cat > $(echo out)`) → **bail** (subtree scan).
  - target is `/dev/null` → safe.
  - fd duplication (`>&N`, `N>&M`) → safe.
  - any other target node (a `word`/`string` filename) → **bail** (file write).
  - This includes the `&>`/`&>>` combined-redirect operators — they are file
    writes and must bail.
- `heredoc_redirect`, `herestring_redirect` → **bail** (not modelled;
  fail-closed). This wholesale bail also covers a substitution in a here-string
  target (`cat <<< $(rm x)`). Both are input-only and could be allowed later —
  start conservative.

`variable_assignment` (statement-level, inert — executes nothing itself):
- value is a literal (`word`/`string`/`raw_string`/number) → safe.
- value is `command_substitution` → recurse into it (§ Substitution safety).
- value is an `array` → **recurse into its elements**, not blanket-accept: an
  array can contain a substitution (`arr=($(rm x))` must prompt; `arr=(a b c)`
  is safe). Apply the same inner-command guard as a scalar substitution value.
- value contains `process_substitution`/arithmetic we don't model → bail.

`command_substitution` (reached ONLY as a statement-level `variable_assignment`
value or array element — see § Substitution safety):
- Treat its inner statement(s) exactly like a top-level command list: recurse
  `walk` over the inner `command`/`redirected_statement`/`pipeline`/`list`.
  Every inner command must be auto-approvable, AND a redirect inside it
  (`f=$(foo > bar)`) is caught by the same `file_redirect` classification.
- Reached in any other position (command argument, command name,
  command-prefix assignment, `for`-list, redirect target, here-string) → the
  parent's subtree scan bails before recursing here.

Explicitly rejected node types (bail), each with the reason it must stay on the
*reject* list rather than the recurse list:
- `subshell` (`( rm -rf x )`), `process_substitution` (`<(ls)`),
  `if_statement`, `case_statement`, `function_definition` — unmodelled control
  flow.
- `negated_command` (`! rm x`), `compound_statement` (`{ rm x; }`),
  `test_command` (`[[ -f x ]]`) — these are new node types confirmed by probe.
  `negated_command` and `compound_statement` **contain a `command` child**, so
  a future maintainer might be tempted to add them to the recurse list — that
  would let `! rm x` approve if `rm` were ever allowed, inverting intent.
  Listed here explicitly so the reject is deliberate, not incidental.
- the catch-all default — any node type not named above.

## Substitution safety (§) — assignment position ONLY

Decision: **allow command substitution as a `variable_assignment` value only;
reject it in command-argument, command-name, `for`-list, and redirect-target
positions.**

### Why argument position is rejected (the `find $(echo '-exec rm')` case)

Auto-approval is sound only when the **static text the matcher inspects
reflects what actually runs.** Argument-position substitution breaks that, and
specifically **launders the dangerous tokens past the `deny`/`ask` layer** —
the very mechanism that makes broad allow patterns tolerable.

- Broad allow patterns like `Bash(find *)` are only safe *because* the
  destructive argument forms are carved out by deny/ask
  (`Bash(find * -exec *)`, `Bash(* -delete *)`). A literal `find . -exec rm …`
  matches that deny pattern and prompts.
- `find $(echo '-exec rm')` does **not** match the deny pattern — the matcher
  only sees `$(...)`, not the `-exec rm` sealed inside it. At runtime the
  substitution expands and `find` receives `-exec rm` as arguments and executes
  the deletion. So the substitution converts a would-be-**denied** command into
  an **approved** one.
- This is not unique to `find`: any "read-only-looking" command with a write
  flag is a vector — `sort -o $(echo out) in` writes a file, etc. You cannot
  statically know a command is arg-independent-safe, so no allow entry is
  immune.

The earlier "substitution only fills a `*` slot, so grants nothing the pattern
didn't" reasoning was **wrong**: a literal in that slot is still subject to
deny/ask filtering and operator splitting (`;`, `|`, `&`); the substitution
text `$(...)` evades all of it while the runtime expansion does not.

### Why assignment position is accepted

`f=$(X)` puts X's output into a variable. In *this* statement it becomes
arguments to nothing — the statement runs only the assignment, plus X itself as
a side effect, which the recursion guard covers (`f=$(rm -rf /)` prompts
because `rm` is not auto-approvable; `f=$(foo > bar)` prompts because the
recursion's `file_redirect` check fires). The dangerous expansion is deferred
to a later, separately-evaluated use site.

The use site (`find $f`) inherits the **pre-existing** limitation that
text-based deny patterns cannot see through *any* dynamic expansion —
variables, globs, `~` — which the system already tolerates today. Allowing the
assignment does not widen that; it only avoids a spurious prompt on the
inert assignment itself. Allowing *argument-position* substitution, by
contrast, would newly open a laundering path that is closed today (since
`$(...)` currently bails entirely).

**Net:** assignment-position substitution removes a false prompt without adding
trust; argument-position substitution would add a real, currently-closed hole.

## Loop support (§)

`for_statement` and `while_statement` join the whitelist. Same recursive
machinery, with loop-specific header checks:

`for_statement`:
- List items (`word`, `glob_pattern`, `string`, `raw_string`, array) → must be
  **literal/glob**. Run the subtree-substitution scan over the list: a
  `command_substitution` anywhere in it (`for f in $(ls)`, `for f in a $(ls) b`)
  → **bail**: the substitution's output becomes the loop values, which flow into
  body command arguments — the same arg-position laundering rejected in
  § Substitution safety, just deferred through the loop variable.
- `do_group` body: recurse `walk` over every command. Loop variable refs
  (`$f`, `variable_ref`) in the body are opaque expansions subject to the
  pre-existing variable-laundering limitation (same as any `$var` use); the
  body is bounded by its commands' allow patterns. So `rm "$f"` only approves
  if `rm *` is allowed (it should not be).

`while_statement` / `until_statement`:
- Condition is a `command` (e.g. `read l`) — recurse, must be auto-approvable.
- `do_group` body: recurse as above.

`if_statement`/`case_statement` stay rejected for now — same machinery, natural
follow-up once loops are proven.

Note on the zsh parser: it handles short-form and standard loops, but any
variant it misparses sets `has_error` → bail. Loop support cannot introduce an
over-approval through a parse the grammar gets wrong, because step 3 rejects
any tree with errors.

## Implementation steps

1. **(Defence-in-depth) Audit `permissions.json`** for allow-bucket commands
   whose dangerous forms lack a `deny`/`ask` carve-out. Pure data, no logic —
   not load-bearing for the substitution decision (arg-position substitution is
   rejected outright), but the deny/ask patterns remain the guard for the
   *literal* dangerous forms. Two distinct classes:
   - **Arg-controlled writes** — a write triggered by a *flag*, invisible to
     the structural redirect classifier (which only catches shell-level
     `file_redirect` nodes). The precedent is established: every other
     flag-writer in a permissive bucket already has a deny carve-out
     (`sed -i*`, `curl * -o *`, `mlr * -I*`, `ruff * --fix*`, `stylua *
     --replace*`). **`sort` (in `read_only`) is the one missing case** —
     `sort -o FILE` / `sort --output=FILE` writes a file. Add
     `Bash(sort * -o *)` and `Bash(sort * --output*)` to **`deny`** (matching
     its siblings; `awk * > *` lives in `ask` only because it is a *redirect*
     writer, which the parser already catches structurally — flag-writers need
     the explicit pattern). Re-scan the buckets for any other flag-writer with
     no carve-out.
   - **Arg-controlled code execution** — sharper than a write: a command in a
     permissive bucket that can run *arbitrary other commands* through its own
     program text, with no shell metacharacter to trip the matcher.
     - `awk` (in `read_only`): the in-program *redirect* form
       (`awk '{print > "f"}'`) is already caught — the literal `>` matches the
       `awk *>*` / `awk * > *` `ask` patterns — and the pipe form
       (`awk '{print | "cmd"}'`) is caught because the `|` breaks the
       operator-excluding `awk *` glob. The genuine hole is
       `awk 'BEGIN{system("rm -rf /")}'`: no `|`/`;`/`&`/`>`, so it matches
       `awk *` allow and nothing in deny/ask → auto-approves and executes `rm`.
       `system` is a builtin name that must appear literally in awk source, so
       a `Bash(awk *system*)` **`deny`** entry closes the inline-program vector.
       Residual: `awk -f scriptfile` (program read from a file) is out of the
       matcher's reach, but writing that script is itself a separately
       permission-gated operation, so this is acceptable — note it as a known
       limitation rather than chase it.
     - `sed` (in `read_only`) has the analogous `e` command (`sed '1e rm -rf /'`,
       `sed 's/x/y/e'`) which executes shell commands; only `sed -i` is carved
       out today. Add `Bash(sed *e*)`-style coverage **only if** it does not
       over-reject common `sed` usage (the letter `e` is ubiquitous in sed
       scripts) — likely needs anchoring to the `e` *command*/*flag* forms
       (`sed '...e'`, `sed * e *`), or accept the residual and document it. Flag
       for the user: a precise sed-`e` carve-out may not be expressible as a
       glob without false positives; if so, the honest options are (a) demote
       `sed` out of `read_only`, or (b) accept the `e`-command residual as a
       documented limitation.
2. Add a private `parse_command(command)` helper: pcall `get_string_parser`,
   return `nil` on failure or `has_error`.
3. Add a private `subtree_has_unguarded_substitution(node)` helper used by the
   `command`, redirect-target, and loop-list handlers (see § the
   substitution-anywhere scan).
4. Implement `walk(node, ctx)` with the whitelist dispatch above. Factor the
   per-command text-extraction + pattern match into a small helper that reuses
   `matches_any_pattern` / the compiled pattern lists.
5. Rewrite `should_auto_approve` to: load patterns → parse → walk.
6. Delete the replaced functions (`split_command`, `mask_quoted_operators`,
   `has_unsafe_redirect`, `strip_devnull_redirects`, `is_inert_segment`, dead
   parts of `strip_wrapper_prefixes`). Keep any still referenced by the matcher.
   `is_inert_segment`'s job (a statement of only assignments executes nothing)
   moves to the statement-level `variable_assignment` arm — confirm the existing
   approve-cases `f=path/to/file; ls "$f"` and `a=1 b=2` still pass (the latter
   parses as two `variable_assignment` siblings, not a `command` with `a=1` as
   the command name — add it as a test).
7. Run `make validate`.

## Testing strategy

- **The behavioural corpus is the contract.** Every existing
  input→approve/prompt case in `permission_rules.test.lua` must still pass —
  it is the safety net for the rewrite. Cases that asserted on the *internals*
  of deleted functions (`split_command returns nil for $(...)`,
  `mask_quoted_operators`, …) get rewritten to assert on `should_auto_approve`
  end-to-end behaviour instead (the observable contract is unchanged: `echo
  $(whoami)` with only `echo` allowed → still prompts, because `whoami` is not
  allowed).
- **New positive cases:** `f=$(echo hi)` approves (echo allowed);
  `for f in *.txt; do cat "$f"; done` approves (cat allowed); `echo '$(foo)'`
  approves; `$((1+2))` handling; `a=1 b=2` approves (two inert assignments);
  `arr=(a b c)` approves (literal array); `ls # rm -rf /` approves (comment
  ignored, dangerous text in comment does not leak into matched command text).
- **New negative cases (substitution laundering) — these are the vectors the
  grammar probe exposed; each must be in the corpus or the safety net has a
  hole:**
  - `grep $(cat list) f` **prompts** (arg-position substitution rejected even
    though grep+cat are allowed).
  - `echo "$(rm -rf x)"` **prompts** (substitution inside a double-quoted arg —
    `string` node, not a direct child).
  - `echo a$(whoami)b` **prompts** (substitution inside a `concatenation` arg).
  - `ec$(echo ho) hi` **prompts** (substitution in a `concatenation`
    command-name).
  - `foo=$(rm x) ls` **prompts** (command-**prefix** assignment substitution
    side effect — distinct grammar position from the allowed statement-level
    assignment).
  - `cat > $(echo out)` **prompts** (substitution in a redirect target).
  - `cat <<< $(rm x)` **prompts** (here-string wholesale bail).
  - `arr=($(rm x))` **prompts** (substitution inside an array value — must
    recurse, not blanket-accept).
  - `find $(echo '-exec rm')` **prompts**; `for f in $(ls); do …` **prompts**
    (substitution in for-list).
  - `$(echo rm) -rf /` and `$(rm -rf /)` **prompt** (dynamic command word).
  - `f=$(rm x)` **prompts** (rm not allowed, recursion); `f=$(foo > bar)`
    **prompts** (redirect inside subst).
- **New negative cases (redirect / quoting / control flow):**
  - `cat foo &> out`, `cat foo &>> out` **prompt** (combined-redirect file
    writes).
  - `"rm" -rf /` **prompts** (quoted-string command name resolves to `rm`,
    not in allow — verify the matcher strips the quotes so it does not
    accidentally match a *different* pattern).
  - `! rm x` (`negated_command`), `{ rm x; }` (`compound_statement`),
    `[[ -f x ]] && rm y` (`test_command`) **prompt** (explicit rejects).
  - truncated/`has_error` input (`rm -rf / |`) **prompts**;
    subshell `( rm -rf x )` / process-sub `cat <(ls)` **prompt**.
- **New negative cases (defence-in-depth data, step 1):** `sort -o out in`
  **prompts** (flag-write deny carve-out); `awk 'BEGIN{system("rm -rf /")}'`
  **prompts** (code-exec deny carve-out).
- **Parser availability:** add a guard test that `should_auto_approve` returns
  false (not error) when the parser is forced unavailable. Confirm `zsh.so`
  resolves in the headless mini.test env before relying on it (it is on rtp at
  `site/parser/zsh.so`).
- **Grammar-pin caveat:** node names can drift across tree-sitter-zsh versions;
  the new tests pin against the installed grammar. Document the regenerate/
  upgrade dependency in a comment.

## Risks / caveats

- **zsh parser limitations** (from nvim CLAUDE.md): `~` in test brackets
  misparse, glob-qualifier delimiters, builtins parse as generic commands.
  None compromise safety — misparse → `has_error` → bail; an
  unmodelled-but-clean node → not whitelisted → bail.
- **Performance:** parsing one short command is sub-ms; negligible in a
  human-speed permission path. Synchronous parsing is safe here (no
  event-loop yield, unlike `vim.system`).
- **Blast radius:** large rewrite of a security module. Mitigated by keeping
  the matching layer untouched and the behavioural corpus as the contract.
- **Docs to update on completion:** `AGENTS.md` § "Compound Bash commands"
  (the split-on-operators description becomes a tree-walk description) and the
  project `CLAUDE.md` client-side auto-approval bullet #2.
