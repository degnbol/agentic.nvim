# Plan: a quoted dynamic word that cannot be an option
Status: reviewed spec
Priority: P3
Depends:

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `token_is_dynamic`,
  `unescape_double_quoted`, `static_string_text` (`"`-delimited check),
  `join_adjacent_args`, `rm_operands`, every `args_dynamic boolean[]`
  annotation
- `lua/agentic/utils/permission_rules.lua` — `extract_args`,
  `structured_reason`, the `rm` branch of `walk_command`, every
  `args_dynamic boolean[]` annotation
- `lua/agentic/utils/executed_code.lua` — `Reader` alias,
  `has_unread_word`, `anchor_dir`, `runs_code` (annotations)
- `lua/agentic/utils/permission_structured.lua` — `agentic.ParsedLeaf`,
  `ExistCtx`, `ForallCtx` (field docs), `build_exist_ctx` (`has_dynamic`,
  `leading_dynamic`), `build_forall_ctx` (`n_static`, `word_values`),
  `scope_after`, `every_stream_matches`, `option_values_must`,
  `gate_matches_existential`
- `lua/agentic/utils/shell_parse.test.lua`,
  `lua/agentic/utils/permission_structured.test.lua`,
  `lua/agentic/utils/permission_rules.test.lua`
- `lua/agentic/utils/permission_structured.lua` — `write_values` must not
  read a dynamic value word as a path
- `notes/FEAT-any-positionals-gate.md` — its `every_parse_has_positional`
  stops at `ctx.n_static`, which keeps its meaning here
- Skills: `permissions` (`references/parsing.md` § Token expansion)

## Background
A leaf with any dynamic word cannot satisfy an option condition:
`ExistCtx.has_dynamic` makes every `options` gate and `option_values` may
hold, and `build_forall_ctx` stops reading options at the first dynamic
word, because "one may expand to an option, `--`, or several words". So
`curl -o /tmp/f "https://host/$p"` and `gh api -X GET "/repos/$r"` are not
approved, though neither dynamic word can be an option.

A double-quoted word expands to exactly one word whatever the shell
options, except through an expansion that splits inside quotes. Measured
with `zsh -f`, `x="a -o b"`, counting the words `"u/…"` delivers:

| Expansion | Words |
|---|---|
| `$x`, `${x}`, `$arr`, `$*` | 1 |
| `$x` with `shwordsplit`, `globsubst`, `rcexpandparam` or `ksharrays` set | 1 |
| `${=x}` | 3 |
| `$@`, `${arr[@]}`, `${(@)arr}` | 2 |

When the word's delivered text up to its first expansion is non-empty and
does not start with `-`, it is never an option and never `--`. The check
reads delivered text, not source: `"\<newline>-$x"` delivers `-a` (zsh
removes `\<newline>`). The word's text is still unknown, so it stays
dynamic for positional globs, option values, subcommand names and deny
gates. Only the two places that ask "may this word be an option or several
words" change: `has_dynamic` and the end of the forall option read.

## Changes
### `shell_parse.lua`
```lua
--- How a word's value is known: false = static; true = dynamic, may
--- expand to any number of words, options included; "single" = dynamic,
--- always one word that does not start with `-`.
--- @alias agentic.WordDynamic boolean|"single"

--- How a word's value is known. `"single"` for a `"`-delimited string
--- whose every expansion is a `variable_ref` or `expansion` node with
--- `simple_variable_name` as its only named child, and whose delivered
--- text before the first expansion (`unescape_double_quoted`) is
--- non-empty and does not start with `-`.
--- @param node TSNode an argument node
--- @param src string
--- @return agentic.WordDynamic
function M.word_dynamic(node, src)
```
Built on `token_is_dynamic`: a static word gives false, a dynamic word
that fails the test gives true. Rejected shapes, by node: `$x[1]`,
`$x[@]` (`index:` child), `$x:h` (`modifier:`), `${=x}`, `${#x}`, `${^x}`,
`${~x}`, `${+x}`, `$=x`, `$^x` (`expansion_style`), `$#`, `$-`, `$1`, `$@`,
`$*` (`special_variable_name`), `${x:-a b}` (`expansion_default`),
command substitutions.
- `rm_operands`: `dynamic = not not argv_dynamic[i]`; its @return doc
  says the flag is true for any dynamic word.
- `agentic.WordDynamic[]` replaces `boolean[]` in every `args_dynamic`/
  `argv_dynamic` annotation that a walk's array reaches: `join_adjacent_args`,
  `rm_operands`, `builtin_bind_targets`, `host_actions`, `action_spans`,
  `code_word`, `inner_source`, `script_file_source`, `cd_target`. Remove the
  `--[[@as boolean[] ]]` casts that hide the type. `extract_commands`
  keeps its own boolean array.

### `permission_rules.lua`
- `extract_args`: where a word is classified with `token_is_dynamic`, use
  `ShellParse.word_dynamic`. `$(…)` and `"$(…)"` stay `true`.
- `structured_reason`: test for any truthy element, not
  `list_contains(…, true)`.
- Annotations: `extract_args` @return, `script_operand`,
  `classifies_read_only`, `refuses_builtin`, `parsed_actions`.

### `executed_code.lua`
- Annotations: `Reader`, `has_unread_word`, `anchor_dir`, `runs_code`.

### `permission_structured.lua`
- `agentic.ParsedLeaf.args_dynamic`: `agentic.WordDynamic[]`.
- `build_exist_ctx`: `has_dynamic` and `leading_dynamic` count only `true`
  words; a `"single"` word cannot expand to a flag. Positional matching
  keeps its per-word truthy tests.
- `ForallCtx` gets `dynamic` (the leaf's array) and `n_options`:
  - `n_static` keeps its meaning, the last word before the first truthy
    word, so `every_stream_matches` (and the `any_positionals` plan) still
    end the positional stream at any dynamic word.
  - `n_options` bounds the option read (`sure_flags`, `sure_leading`,
    `word_values`): the last word before the first `true` word, or before
    a `"single"` word that some state in `reached[i]` reads at scope `""`
    while the command's `arity` has a scope key other than `""` and `"*"`
    (`scope_after` would read its text). It is found in the main loop, not
    in the pre-pass.
  - `word_values[i]` is nil when the value word is dynamic (any truthy
    value), so `option_values_must` never matches raw text.
  Update the field docs and the `build_forall_ctx` docstring.
- Docstrings: `option_values_must` ("False when the leaf has a word that
  may expand to an option"), `gate_matches_existential`.

### Tests
- `shell_parse.test.lua`, `word_dynamic`: `"single"` for `"https://h/$p"`,
  `"a${b}c"`; true for `"$p"`, `"-$p"`, `"\<newline>-$p"`, `"u/${=p}"`,
  `"u/$@"`, `"u/${a[@]}"`, `"u/${(@)a}"`, `"u/$a[1]"`, `"u/$a:h"`,
  `"u/${#a}"`, `"u/$#"`, `"u/${a:-b c}"`, `u/$p` (unquoted); false for
  `'u/$p'` and `"abc"`.
- `permission_structured.test.lua`: a `"single"` word does not set
  `has_dynamic` or `leading_dynamic`; `option_values_must` holds for
  `-X GET` beside a `"single"` word and fails for `-X "G$x"`
  (`"single"` value word); `every_stream_matches` fails at a `"single"`
  positional a glob would match by its source text; with a literal-scope
  arity, a `"single"` first positional ends the option read; with only
  `"*"` arity it does not.
- `permission_rules.test.lua`: `gh api -X GET "/repos/$r"` approves;
  `gh api -X GET "$r"`, `gh api -X GET "-$r"`, `gh api -X "G$m" /x` do
  not; `curl -sS "https://h/$p"` approves; `rm "/tmp/$x"` gives no effect
  and is not approved.

### Docs
- `permissions` skill, `references/parsing.md` § Token expansion: a
  `"single"` word does not count as a possible option; its text still
  wildcards.

## Expected outcome
- `gh api -X GET "/repos/$r"` and `curl -sS "https://h/$p"` approve.
- `curl -sSL --max-time 15 -o
  /tmp/s.out -w '[%{http_code}]' "https://sabiork.h-its.org/$p"` and the
  URL-first order (`curl -sS "https://h/$p" -o /tmp/s.out`) approve through
  the `/tmp` grant.
- An unquoted `$p`, a word starting with an expansion, a splitting
  expansion and a dynamic value word stay as today.

## Non-goals
- Unquoted words: `SH_WORD_SPLIT` and `GLOB_SUBST` in the user's shell
  options would split or glob them.
- A word starting with an expansion whose value is known not to start
  with `-` (`"$HOME/x"`): the value is not read.
- `ShellParse.extract_commands` records (file activity, `eval` joins):
  they keep their boolean `argv_dynamic`.

## Open questions
