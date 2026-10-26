# Shell command parsing — matcher internals

## Over-approximation (sound for deny/ask)

The matcher over-approximates option presence per token (single-dash `-uo`
expands to letters `{u, o}` AND long-name `uo`; double-dash `--output=x`
becomes prefix-matched long-name `output`), which is sound for deny/ask —
extra candidates can only widen a match, never miss one. This is why the
structured layer beats globs against option clustering and GNU abbreviation
(`sort -uo out`, `sort --out=x`, `sort -oFILE` all evade `Bash(sort * -o *)`).

A token is split at whitespace. Each segment that starts with `-` is read
as its own dash word (perl reads `-p -i` in one word as two switches). The
other segments, and a `--name=value`'s value, are dropped (getopt exits at
the whitespace or has already taken it as a value).

## Arity — absorption parses

**Arity is matched, not guessed.** The walker emits an ordered word list
(`{cmd_name, args}`, each arg tagged only with whether it expands at runtime);
no role/arity tagging. A dash word may or may not take the next word as its
value, and the two directions read that ambiguity dually:

- *deny/ask are existential* — a gate fires if **any** absorption parse exposes
  the gated subcommand/option. A linear prefix-walk collects the possible
  first-positional (subcommand) indices; the rare multi-element positional gate
  enumerates parses (bounded). An over-match only over-prompts.
- *allow is universal* — a gate must hold in **every** parse: an option counts
  only if no parse takes it as a value, a positional element only if every
  parse's stream matches. An entry's `arity` hints (`takers`/`booleans` per
  scope: `""` before the first positional, a literal first positional, `"*"`)
  cut parses; an absent hint only adds a prompt, a present one is trusted.

So `git -C /repo log` auto-approves (`-C` is a hinted taker), while
`git -C push log`, `git -p push`, and `git --new-global val push` all
prompt — the took-0 parse exposes `push`. Every dash-token is stripped to the
option fields; only `-` (stdin/stdout sentinel) and the words after a `--`
that ends options are positionals. For deny/ask, a `--` directly after a flag
may be its value, so options continue: `tar -tf -- --use-compress-program=x`
exposes `use-compress-program`.

## `leading_options`

A gate field matching a flag only in the leading region (before the first
positional), for a code channel whose danger is position-specific: git's
leading `-c core.pager=!cmd` runs code before the subcommand, but `git log -c`
is the harmless combined-diff flag and a trailing `$ref` can never inject a
leading flag. On allow, it gates a mode flag that counts only before the
operand (`command -v` is a lookup only there); it must precede the first
positional in every parse.

## Token expansion: resolve statically, else dynamic

Imprecision is one-directional — it may only ever over-prompt, never
auto-approve something the gates would otherwise catch. So a token's concrete
value is resolved wherever it provably can be, and falls back to a conservative
"could be anything" otherwise.

**Resolved** — a literal, or a `$name`/`${name}` (bare or its single-word quoted
form `"$name"`/`"${name}"`) bound to a *splitting-proof* literal (`is_safe_literal`
— no IFS whitespace, glob/brace/tilde, or expansion trigger) earlier in the same
straight-line sequence. `walk_sequence`/`tally_sequence` thread a per-sequence
`known` environment left to right; `resolved_var_name` accepts only a lone
`simple_variable_name` (recursing through a single-child `string` for the quoted
form), so `$f[1]`, `${f:-x}`, quoted concatenation `"$f/x"`, and `"$(cmd)"` are
excluded. The resolved value feeds the same gates, so `f=/safe; find $f` and
`find "$f"` approve while `f=--exec; find $f` denies. An **unquoted**
concatenation (`$d/x`, a `concatenation` node) is resolved by a separate
`resolved_concatenation` pass in `extract_args`, not `resolved_var_name`: it joins
each part — an inert `pure_literal_token` part or a `known`-bound var — requiring
every part to pass `is_safe_literal`, else the whole token stays dynamic.
`base=/safe; head $base/x` resolves to `/safe/x` (approves); `base=-o; sort
$base/x` resolves to `-o/x`, whose short-flag clustering hits sort's write gate
(prompts). The `/x` suffix means the join can never *be* a bare flag, so
`base=--exec; find $base/x` → `--exec/x` (unknown find predicate, not `-exec`) —
approves. A quoted concatenation `"$f/x"` (a `string` node) is *not* statically
resolved and stays dynamic.

A **for-loop over an all-literal list** (`is_safe_literal` per item, plain loop
var) is another `known` source: `walk_for` unrolls the body once per value,
seeding `walk_sequence` with `{ [loopvar] = value }`, and approves iff every
value approves. So `for d in acp permissions; do find . $d/SKILL.md; done`
resolves each body reference to a concrete path and approves, while `for d in acp
-delete; do find . $d; done` binds `d=-delete` on one pass and prompts (find's
deny gate). Nested literal loops divide a shared `ctx.for_budget` (`FOR_UNROLL_CAP
= 64`) per level; a non-literal list (`for f in $(ls)`) or an over-budget count
falls back to a single dynamic-token walk of the body.

**Dynamic** — anything unresolvable: an unbound `$var`, an unquoted glob (`~` is
exempt — it only yields a path, never a flag/subcommand), substitution output,
or a substitution-free unquoted concatenation with a glob/unbound-var/expansion
part (`head $d/SKILL.md` — the whole `$d/SKILL.md` splices as one dynamic token
via `literal_token`'s raw-text fallback; `token_is_dynamic` recurses its children
so a nested `-ex"$x"c` counts too). Treated as satisfying any `options`
requirement and any positional at or
after its reachable index, so a payload laundered through `$f` at a gated command
prompts — guarding the bare (`find $f`), assignment (`f=$(…); find . $f`), and
loop-body (`for f in *.txt; do find . $f`) vectors at the single use site.
Wildcarded only against deny/ask, **never allow**: a dynamic subcommand fails the
allowlist (→ prompt) and a trailing dynamic arg (`git log $ref`) is harmless, so
a dynamic token never widens an approval.

**Arithmetic that reads a value fails the parse.** zsh, like bash, evaluates a
variable's value as arithmetic when arithmetic names it, and a subscript in that
value runs its command substitutions (`n='y[$(cmd)]'; echo $((n))`). So
`parse_zsh` returns nil for any arithmetic with a letter or a `$` other than
`$#`/`$?`/`$$`/`$!`: a `$((…))`/`$[…]` body, a subscript, a `${x:off:len}`
offset or length, an array literal's `[key]=`, a `[[ … -eq … ]]` operand. The
walk applies the same test to the arguments of builtins that evaluate them
(`shift`, `return`, `exit`, `logout`, `break`, `continue`; for `printf`/`print`
the subscript of a `-v` target and the arguments after a format with any
directive but `%s`/`%b`/`%c`/`%q`, a `*` width or a `$`). Rules per node type:
`SIDE_EFFECT_SYNTAX` in `shell_parse.lua`.

**Static arithmetic** — an `arithmetic_expansion` that passes the parse
(`$((40))`, `"$((40))p"`, `-$((5))`) is *static* at argument position, in
every shell: its output is always an integer, never a flag/subcommand/path. It
stays dynamic at a redirect target, which needs the literal path. The `string`
classifier is a whitelist — arithmetic mixed with a `$var`/`$(…)` child stays
dynamic.

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

## Arg token text — quote handling by class

A leaf's arg tokens (the `args` strings, joined for the glob matcher) are
quote-handled by *class*, not uniformly. The rule that matters: the strip only
applies to a **concrete literal** feeding literal matching; a token that is
dynamic or mixed keeps its quotes, because its text is never literal-matched
(the structured matcher wildcards a dynamic token and ignores its text).

| String form | Stored token | Why |
|---|---|---|
| Pure literal `"rm"` (`string_content` only) | `rm` (stripped) | A concrete literal must not evade a literal gate by keeping quotes. |
| Pure literal with escapes `"a\$" "a\"b" "a\qb"` | `a$` `a"b` `a\qb` | Read from the source between the quotes, unescaped as zsh does in double quotes (`\$ \` \" \\` lose the backslash, `\<newline>` goes, other backslashes stay). `"a$"` keeps the `$` the grammar leaves outside any child. |
| Unquoted word `\-exec` | `-exec` | `\x` is `x`, `\<newline>` goes: an escaped flag meets the same gate as the plain one. |
| Byte-adjacent nodes `--include=*.{ts,tsx}` (word + `glob_pattern`, no `concatenation`) | `--include=*.{ts,tsx}` (raw, dynamic) | One shell word, one token (`join_adjacent_args`). The grammar splits a word only at a glob or brace part, so the joined token is dynamic. |
| Mixed `"pre$f"` (`string_content` + expansion) | `"pre$f"` (raw, quoted) | Dynamic — text isn't literal-matched; raw text preserves glob matching. `literal_token`'s mixed branch. |
| Pure substitution `"$(ls)"` (quoted, single child, no literal) | `$(ls)` (inner, no quotes) | Its own branch (the quoted-command-substitution case); no literal part to preserve. |
| Literal + substitution `"count: $(ls)"` | `"count: $(ls)"` (raw, quoted) | Same class as `"pre$f"` — mixed + dynamic, so keep quotes. |

The pure-substitution row's stripped form is the one that looks inconsistent
with the mixed-string rows; it is deliberate (that string has no literal to
keep) and keeps its own branch — do not unify it with the mixed-string
handling.

## Pipeline

1. **Parse** with the zsh treesitter grammar. Fail-closed: no parser, parse
   failure, any error node, or syntax the grammar parses differently from zsh
   (a hidden backtick substitution, a line continuation inside a word), or a
   parameter flag / glob qualifier that runs code (`${(e)x}`, `*(+cmd)`,
   `${~x}`) or an assigning default (`${x::=y}`; `SIDE_EFFECT_SYNTAX` in
   `shell_parse.lua`) → prompt. The zsh parser is a
   hard dependency.
2. **Walk** reject-by-default. Bail on dynamic command names and code-taking
   builtins (`eval`/`source`/`.`). A **transparent prefix** is not a leaf:
   `inner_source` slices out its inner command and re-walks that on its own
   merits (mis-slice fails closed → prompt). These are a fixed allowlist — a
   shell `-c <body>` (`zsh`/`bash`/`sh`/`dash`) and the exec-wrappers `timeout`,
   `time`, `stdbuf`, `uv run`, `xargs`, bare `command`. `xargs` additionally
   appends a trailing dynamic stdin token, so a gated inner (`xargs sort` → `-o`) prompts while
   read-only inners approve. `extract_commands` also unwraps `uv run` with its
   code-injecting options (it reports what runs); the permission walk does
   not. Anonymous separators
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
   always approves *as a definition* — defining never runs the body.
   Locally-defined-function *call* resolution adds this: the body is also walked
   as a fresh sequence (every `$var`/positional dynamic), and on a clean walk the
   name is recorded in a per-sequence function table (same left-to-right lifetime
   as the per-sequence `known`). A
   later `command` whose name matches a recorded entry approves regardless of
   its call arguments — the body was vetted for arbitrary args, though a
   side-effecting argument substitution (`foo $(rm x)`) is still walked and
   bails. A call before the definition, or to one defined in a different
   sequence, matches no record and is judged as the command of that name. A
   definition with an unsafe body adds every name to a **shadowed** set shared
   by every nested walk of the command; a call to a shadowed name bails in any
   scope or order, even after a clean redefinition. A redirect on the
   definition (`f() { … } > x`) counts as unsafe unless it is a safe form
   (`> /dev/null`, `2>&1`, `<`): zsh applies it at every call. The walk re-runs until the
   set stops growing, so a clean body that calls a name shadowed later still
   bails. Names match the command word as written (`/bin/ls` does not call
   `ls()`). A definition zsh calls without a call site (hook functions,
   `TRAP*`, `command_not_found_handler`, `zsh_directory_name`) bails, and so
   does an **anonymous** function (`() { … }`, no `name` field), which executes
   immediately. A brace group `{ …; }` is the
   same `compound_statement` node and walks like a `list`.
   A bare `command_substitution` (`$(…)` / backticks) in **argument**,
   **for-list**, or **assignment-value/array-element** position recurses
   through `walk_substitution_inner`: its inner commands must approve
   standalone (so `f=$(rm x)` and `cat $(rm x)` bail — `rm` not allowed). A
   quoted `"$(…)"` in **argument** position (a `string` whose single named child
   is the substitution) is unwrapped to that inner and walked the same way
   (`cat "$(ls)"` approves). This generalises to a quoted string mixing literal
   text with one or more substitutions and nothing else (`echo "count: $(ls)"`,
   `cat "pre$(ls)"`, `echo "a $(ls) b $(wc -l)"`): every inner recurses, then the
   *whole quoted argument* splices as one dynamic token (quotes kept, since a
   dynamic token's text is ignored). A `$var`/`${…}`/arithmetic child fails the
   `string_content`-or-`command_substitution` whitelist and bails. In argument
   and for-list position the output is
   then spliced in as a *dynamic token*, so a gated outer command still prompts
   — `find . $(echo -exec rm)` and `find . "x$(echo -exec rm)"` approve the inner
   `echo` but the dynamic token wildcard-fires find's `-exec` gate. A process
   substitution `<(…)`/`>(…)` in **argument** position also recurses through
   `walk_substitution_inner`, then splices a *static* `/dev/fd` placeholder (it
   expands to a `/dev/fd/N` path, never a flag or subcommand). Still bails
   (output is a control surface the dynamic-token machinery can't guard):
   substitution as the command name (`$(echo rm) x`), an unquoted concatenation
   *bearing a command substitution* (`a$(b)c` — a substitution-free one like
   `$d/x` splices as a token instead, see "Token expansion") or a quoted string
   mixing `$var`/`${…}`/arithmetic with text (`"$a$b"`, `"x$y$(ls)"`),
   process substitution outside argument position, case value/pattern, a quoted
   `"$(…)"` for-list item, and redirect target (`cat > $(echo f)`).
3. **Classify** redirects and env-prefixes structurally. `> /dev/null` and
   FD duplication (`2>&1`) are safe; any other file redirect bails. An env
   prefix whose name fails `is_safe_var_name` bails.
4. **Extract** each safe leaf — the command name and quote-stripped arg
   tokens, minus redirects and env-prefixes. The leaf goes to the glob
   matcher as a joined string; the tokenised form (`{cmd_name, args}`)
   goes to the structured matcher. A system binary-dir prefix is stripped
   from the command name (`strip_command_path`).
5. **Check** against compiled patterns and structured entries, sourced
   per layer:
   - Bundled `lua/agentic/permissions.json` (when
     `Config.permissions.use_plugin_defaults`) — structured entries only.
   - `settings.json` in Claude's config dir (`PermissionRules.settings_paths`)
     and `.claude/settings.json` (when
     `Config.permissions.use_claude_settings`) — glob patterns.
     Mtime-cached.
   - `Config.permissions.structured` — structured entries.
     Recompiled on table-reference change.
6. **Resolve** the allow list per `Config.permissions.auto_approve_tier` and
7. **compose** per leaf: SKILL.md § "Composition per leaf".

## Command-source fallback

If `request.toolCall.rawInput.command` is nil and the tracker kind is
`"execute"`, read from `tracker.argument` instead (opencode quirk — see acp
skill `references/opencode.md` finding 3).
