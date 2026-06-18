# Shell command parsing — matcher internals

Token-level mechanics behind the **Shell command parsing** auto-approval
mechanism. The conceptual model — what the two layers guarantee, the
safety-not-correctness boundary, composition, and residual risk — lives in
[../SKILL.md](../SKILL.md). This file is *how the matcher decides per token*;
read it before changing `permission_rules.lua` or `permission_structured.lua`.

## Over-approximation (sound for deny/ask)

The matcher over-approximates option presence per token (single-dash `-uo`
expands to letters `{u, o}` AND long-name `uo`; double-dash `--output=x`
becomes prefix-matched long-name `output`), which is sound for deny/ask —
extra candidates can only widen a match, never miss one. This is why the
structured layer beats globs against option clustering and GNU abbreviation
(`sort -uo out`, `sort --out=x`, `sort -oFILE` all evade `Bash(sort * -o *)`).

## Arity — absorption parses

**Arity is matched, not guessed.** The walker emits an ordered word list
(`{cmd_name, args}`, each arg tagged only with whether it expands at runtime);
no role/arity tagging. The matcher carries no per-command getopt table — each
leading dash-word may absorb 0 or 1 following plain word, and the two
directions read that ambiguity differently:

- *deny/ask are existential* — a gate fires if **any** absorption parse exposes
  the gated subcommand/option. A linear prefix-walk collects the possible
  first-positional (subcommand) indices; the rare multi-element positional gate
  enumerates parses (bounded). Owns soundness — an over-match only over-prompts.
- *allow is a single parse* — a leading flag absorbs its next word iff it is a
  known value-taker (`value_options`, a fail-safe optimisation; an unlisted flag
  absorbs 0, only over-prompting). Convenience only: the existential pass has
  already cleared every parse. Single-parse — *not* existential — keeps an
  unknown subcommand → prompt, so a leading bare flag cannot launder a dangerous
  subcommand to a read-only alternate parse.

So `git -C /repo log` auto-approves (`-C` absorbs `/repo`, subcommand `log`),
while `git -C push log`, `git -p push`, and `git --new-global val push` all
prompt — the took-0 parse exposes `push`. Every dash-token is stripped to the
option fields; only `-` (stdin/stdout sentinel) and the words after `--` are
positionals.

## `leading_options`

A gate field matching a flag only in the leading region (before the first
positional), for a code channel whose danger is position-specific: git's
leading `-c core.pager=!cmd` runs code before the subcommand, but `git log -c`
is the harmless combined-diff flag and a trailing `$ref` can never inject a
leading flag.

## Token expansion: resolve statically, else dynamic

Imprecision is one-directional — it may only ever over-prompt, never
auto-approve something the gates would otherwise catch. So a token's concrete
value is resolved wherever it provably can be, and falls back to a conservative
"could be anything" otherwise.

**Resolved** — a literal, or a bare `$name`/`${name}` bound to a *splitting-proof*
literal (`is_safe_literal` — no IFS whitespace, glob/brace/tilde, or expansion
trigger) earlier in the same straight-line sequence. `walk_sequence`/
`tally_sequence` thread a per-sequence `known` environment left to right;
`resolved_var_name` accepts only a lone `simple_variable_name`, so `$f[1]`,
`${f:-x}`, and `"$f"` are excluded. The resolved value feeds the same gates, so
`f=/safe; find $f` approves while `f=--exec; find $f` denies.

**Dynamic** — anything unresolvable: an unbound `$var`, an unquoted glob (`~` is
exempt — it only yields a path, never a flag/subcommand), or substitution
output. Treated as satisfying any `options` requirement and any positional at or
after its reachable index, so a payload laundered through `$f` at a gated command
prompts — guarding the bare (`find $f`), assignment (`f=$(…); find . $f`), and
loop-body (`for f in *.txt; do find . $f`) vectors at the single use site.
Wildcarded only against deny/ask, **never allow**: a dynamic subcommand fails the
allowlist (→ prompt) and a trailing dynamic arg (`git log $ref`) is harmless, so
a dynamic token never widens an approval.

**Invalidation** (`update_known` → `collect_bindings`) drops only the names a
sibling could rebind, defaulting to clear-all when those names can't be
enumerated. A pure-literal `variable_assignment` records its binding; every
other sibling goes to `collect_bindings`, which returns the set of rebound names
(dropped) or signals clear-all. A binding-free sibling (a plain command, a
`[[ … ]]` guard, `if c; then :; fi`, a loop over another var) drops nothing and
`known` survives; an enumerable binder (an `if`-body `d=…`, a `for` loop var,
`printf -v g`) drops exactly those names; an un-enumerable binder (a
namespace-mutating builtin, arithmetic assignment, a `declaration_command`, a
dynamic/subscripted name, or any unmodelled node type) clears `known` entirely —
enumerating every rebinding vector would undercount (`local`/`typeset` are
`declaration_command`, `printf -v`/`read` are `command`, `(( x=… ))` is
`arithmetic_expansion`, none a top-level `variable_assignment`), so anything not
provably enumerable fails closed to clear-all. The scan recurses only statement
positions (`while read x` clears via the recursed condition; `case $x in` skips
the matched value) and stops at subshell / `$(…)` boundaries (those bindings are
sealed). `known` is sequence-local; a binding never leaks into or out of a
nested block.

## Pipeline

1. **Parse** with the zsh treesitter grammar. Fail-closed: no parser, parse
   failure, or any error node → prompt. The zsh parser is a hard dependency.
2. **Walk** reject-by-default. Bail on dynamic command names and code-taking
   builtins (`eval`/`source`/`.`). Anonymous separators
   (`|`, `&&`, `;`, `&`, newline) and comments are skipped. Loops
   (`for`, `while`, `until`) recurse: every body command must itself approve,
   and a `for` list item is a literal, glob, or a bare `command_substitution`
   (recursed — see below). `if`/`case` recurse into every branch (no branch
   prediction): each condition, body, `elif`/`else` clause, and `case` item
   body must approve. A `test_command` (`[[ … ]]`/`[ … ]`) is a
   side-effect-free predicate — safe unless it embeds a substitution
   (`[[ -f $(rm y) ]]` runs `rm`). The `case` value and each `case` item
   *pattern* must be substitution-free too — both run code during the match
   (`case $(rm x) in $(rm y)) …`).
   A **named** `function_definition` (`foo() { … }`, `function foo { … }`)
   always approves *as a definition* — defining never runs the body. #6 adds
   *call* resolution: the body is also walked as a fresh sequence (every
   `$var`/positional dynamic), and on a clean walk the name is recorded in a
   per-sequence function table (same left-to-right lifetime as #3's `known`). A
   later `command` whose name matches a recorded entry approves regardless of
   its call arguments — the body was vetted for arbitrary args, though a
   side-effecting argument substitution (`foo $(rm x)`) is still walked and
   bails. A redefinition with an unsafe body un-records the name; a call before
   the definition, or to one defined in a different sequence (a nested `if`
   body, a subshell), still bails. An **anonymous** function (`() { … }`, no
   `name` field) executes immediately and bails. A brace group `{ …; }` is the
   same `compound_statement` node and walks like a `list`.
   A bare `command_substitution` (`$(…)` / backticks) in **argument**,
   **for-list**, or **assignment-value/array-element** position recurses
   through `walk_substitution_inner`: its inner commands must approve
   standalone (so `f=$(rm x)` and `cat $(rm x)` bail — `rm` not allowed). In
   argument and for-list position the output is then spliced in as a *dynamic
   token*, so a gated outer command still prompts — `find . $(echo -exec rm)`
   approves the inner `echo` but the dynamic token wildcard-fires find's
   `-exec` gate. Still bails (output is a control surface the dynamic-token
   machinery can't guard): substitution as the command name (`$(echo rm) x`),
   string-embedded or concatenated (`"$(…)"`, `a$(b)c`), process substitution
   (`<(…)`), case value/pattern, and redirect target (`cat > $(echo f)`).
3. **Classify** redirects and env-prefixes structurally. `> /dev/null` and
   FD duplication (`2>&1`) are safe; any other file redirect bails. Env
   prefixes that hijack execution (`PATH=`, `LD_*`, `BASH_ENV`) bail.
4. **Extract** each safe leaf — the command name and quote-stripped arg
   tokens, minus redirects and env-prefixes. The leaf goes to the glob
   matcher as a joined string; the tokenised form (`{cmd_name, args}`)
   goes to the structured matcher. `stdbuf` wrappers and system
   binary-dir prefixes are stripped on the command name.
5. **Check** against compiled patterns and structured entries, sourced
   per layer:
   - Bundled `lua/agentic/permissions.json` (when
     `Config.permissions.use_plugin_defaults`) — structured entries only.
   - `~/.claude/settings.json` and `.claude/settings.json` (when
     `Config.permissions.use_claude_settings`) — glob patterns.
     Mtime-cached.
   - `Config.permissions.{read_only, safe_write, deny, ask}` — glob
     patterns. `Config.permissions.structured` — structured entries.
     Recompiled on table-reference change.
6. **Resolve** the allow list per `Config.permissions.auto_approve`. Both
   layers honour the same toggle: `"allow"` accepts entries in
   `read_only` ∪ `safe_write` (mkdir, touch, git add, …); `"read-only"`
   accepts `read_only` only; `nil` accepts no allow rules (compound path
   will not approve; deny/ask still apply).
7. **Compose** per leaf:
   `approve iff (glob_allow OR structured_allow) AND NOT (glob_deny OR
   structured_deny OR glob_ask OR structured_ask)`. Deny/ask are OR across
   layers; allow is union. A leaf approves only when every layer that
   votes against it stays silent.

## Command-source fallback

If `request.toolCall.rawInput.command` is nil and the tracker kind is
`"execute"`, read from `tracker.argument` instead (opencode quirk — see acp
skill `references/opencode.md` finding 3).
