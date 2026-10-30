# Plan: value and negation conditions on structured gates
Status: spec

## Relevant files
- `lua/agentic/utils/permission_structured.lua` — `PermGate`,
  `arity_kinds`, `option_takes_next`, `sure_identifiers`, `ForallCtx`,
  `build_forall_ctx`, `gate_matches_existential`, `gate_matches_universal`,
  `decide_leaf`, `classify_leaf`, `deny_leaf`
- `lua/agentic/utils/option_parse.lua` — new
- `lua/agentic/utils/permission_rules.lua` — `normalise_gate`,
  `normalise_structured_entries`
- `lua/agentic/permissions.json` — `gh`, `curl`
- `~/dotfiles/config/claude/settings.json` — the `gh api` allow (L324) and
  asks (L406-410)
- Tests: `lua/agentic/utils/{permission_structured,permission_rules}.test.lua`
  (the `gh api` cases at `permission_rules.test.lua:2020-2059`)
- Docs: `doc/agentic.txt` § structured rules (L834-850); `permissions` skill
  `SKILL.md` § Shell command parsing, `references/parsing.md`
- Related: `notes/PLAN-permission-walker-dedup.md` moves `normalise_gate`
  into `permission_structured.lua`. Edit the function where it lives when
  this plan runs.

## Background
A structured gate matches on option presence and positionals only. Some
commands are safe or unsafe depending on an option's value, or on another
option being present:

- `gh api -X GET … -f k=v` is a GET with a query string. Without `-X GET`,
  `-f` makes it a POST. `-X` is last-wins, so `-X GET … -X DELETE` sends
  DELETE.
- `curl -o /dev/null`, `curl -D -` write nothing.

A scan of 17,045 unique Bash commands from 90 days of transcripts found
these value/combination patterns (counts of commands): `curl -o /dev/null`
66, `curl -G --data-urlencode` 39, `zsh -n`/`-fn` 38, `curl -D -` 16,
`print -u 1|2` 9, `gh api -X GET … -f` 8.

A general if/else tree per entry was considered. Rejected: in a first-match
tree, an allow branch put before its ask branch approves the write, and
users add rules through `Config.permissions.structured`. The fixed
precedence deny > ask > allow makes an ordering mistake only over-prompt.
The chosen design keeps the precedence and adds boolean structure inside a
gate:

- `not: PermGate[]` — the gate holds only if none of the listed gates hold.
  With the existing AND of a gate's fields and OR of a kind-array, this
  gives full propositional logic.
- `option_values: { options, values }` — some listed option occurs, and
  every occurrence of any listed option has a value that matches a glob in
  `values`. The options are one group, so `-X GET --method POST` fails.

**Evaluation under ambiguity.** A leaf has several parses (unhinted arity,
dynamic tokens). Each gate gets two readings: `may` (holds in some parse;
over-approximates) and `must` (holds in every parse; under-approximates).
The existing existential matcher is `may` of the plain fields, and the
universal matcher is `must`. Negation swaps them: `may(not g) = ¬must(g)`,
`must(not g) = ¬may(g)`. Ask fires on `may`, allow approves on `must`, so
an unclear `not` condition prompts.

**Deny gates do not take the new fields.** `deny_leaf` is concrete-only (a
dynamic token never fires deny) and rejects with no prompt. `may(not g)`
there would be `¬must(g)`, which a dynamic token makes true, so a dynamic
token would fire a hard reject. All found cases are ask exceptions.

**Parsing is a separate layer.** How a word delivers a value to an option
(`-X GET`, `-XGET`, `-X=GET`, `--method GET`, `--method=GET`, a cluster
`-iXGET`) is read by `option_parse.lua`, which also takes the existing
arity helpers. The decision layer in `permission_structured.lua` consumes
only `{id, values}` records and the globs.

**settings.json blocks the change.** `~/.claude/settings.json` has
`Bash(gh api *)` in allow and `Bash(gh api *-X*)`, `*--method*`, `*-f*`,
`*-F*`, `*--input*` in ask. The glob layer votes ask on `-X GET`, so the
structured change has no effect while they exist. Removing only the asks
lets the SDK auto-approve `gh api -X DELETE` in every Claude session. So
all six lines go; `gh api` then reaches the plugin as an SDK `ask` and the
structured rules decide. A session outside agentic.nvim prompts for every
`gh api`.

**Existing hole.** The structured `gh api` ask lists `f` and `F` but not
`raw-field` and `field`: `gh api /x --raw-field a=b` (a POST) classifies
`read_only` today. Only the settings.json `*-f*` glob catches it, so it
must be closed here before the globs go.

## Changes

### 1. `lua/agentic/utils/option_parse.lua` (new)
Pure reading of option words, given arity kinds. Move from
`permission_structured.lua` with no behaviour change: `arity_kinds` (as
`M.kinds`), `option_takes_next` (as `M.takes_next`), `sure_identifiers`
(as `M.sure_identifiers`). The `PermArityKind`/`PermTakesNext` aliases move
with them.

New:
```lua
--- @class agentic.OptionValue
--- @field id string dashless identifier of the option that takes the value
--- @field values string[] candidate values, one per dialect reading

--- The option in `word` that takes a value, and the value it gets.
--- `--name=v` → {name, {v}}. `--name` hinted taker → {name, {next_word}}.
--- A cluster `-abc`: skip hinted booleans; the first other letter must be a
--- hinted taker. Last letter → {letter, {next_word}}. Else the rest of the
--- word is the value: {letter, {rest}}, plus `rest` without a leading `=`
--- when it has one (`-X=GET` is `GET` in pflag, `=GET` in getopt).
--- @param word string a dash word other than `-` and `--`
--- @param next_word string|nil
--- @param kinds table<string, agentic.PermArityKind>
--- @return agentic.OptionValue|nil occurrence nil when no option in the word
---         takes a value, an unhinted option comes first, or a taker is the
---         last word
function M.value(word, next_word, kinds)
```

### 2. `lua/agentic/utils/permission_structured.lua`
- Require `option_parse`; replace the moved helpers' call sites.
- `PermGate` gains `not?: agentic.PermGate[]` and
  `option_values?: agentic.PermOptionValues`:
  ```lua
  --- @class agentic.PermOptionValues
  --- @field options string[] dashless identifiers, one group
  --- @field values string[] globs a value must match
  ```
- `ForallCtx` gains `word_values: table<integer, agentic.OptionValue>`. In
  `build_forall_ctx`, for each options word (the existing `options_word`
  test), call `OptionParse.value(words[i], words[i + 1], kinds)` for every
  reaching state's kinds; store it only when all states give the same `id`
  and values.
- New decision functions:
  ```lua
  --- Whether `cond` holds in every parse: no dynamic word in the leaf, at
  --- least one hit, and every hit — a flag word before the options end
  --- whose existential candidates match `cond.options` — has a
  --- `word_values` entry whose `id` is in `cond.options` exactly and whose
  --- every candidate value matches a glob in `cond.values`.
  local function option_values_must(cond, exist, forall) -> boolean

  --- Whether `cond` may hold: a listed option may occur
  --- (`match_options(exist.flag_cands, cond.options)` or `exist.has_dynamic`).
  --- Values are not read; this only over-approximates.
  local function option_values_may(cond, exist) -> boolean

  --- `gate_matches_existential` ∧ `option_values_may` ∧
  --- every `not` gate fails `gate_must`.
  local function gate_may(gate, exist, forall) -> boolean

  --- `gate_matches_universal` ∧ `option_values_must` ∧
  --- every `not` gate fails `gate_may`.
  local function gate_must(gate, exist, forall) -> boolean
  ```
- `decide_leaf`: build `forall` before the deny loop; ask uses `gate_may`,
  allow uses `gate_must`. Deny keeps `gate_matches_existential`.
- `classify_leaf`: same substitution for ask and the allow kinds.
- `deny_leaf`: no change.

### 3. `lua/agentic/utils/permission_rules.lua` — `normalise_gate`
Takes the kind. Parses `not` (recursively) and `option_values` (`options`
dashless via `normalise_option`, `values` strings). A malformed condition
must fail safe, with a `Logger.notify` WARN:
- ask/deny gate: drop the malformed field and the whole `not` list (the
  gate widens: more prompts or rejects);
- allow gate: drop the gate.
`not` and `option_values` on a deny gate warn and are dropped.

### 4. `lua/agentic/permissions.json`
`gh`:
```json
"ask": [
  { "positionals": ["api"],
    "options": ["X", "method", "f", "raw-field"],
    "not": [{ "option_values": { "options": ["X", "method"],
                                 "values": ["GET"] } }] },
  { "positionals": ["api"],
    "options": ["F", "field", "input", "hostname"] },
  { "positionals": ["issue", "create"] }
],
"arity": {
  "*":   { "takers": ["-R", "--repo", "--hostname"] },
  "api": { "takers": ["-X", "--method", "-f", "--raw-field", "-F", "--field",
                      "-H", "--header", "-q", "--jq", "-t", "--template",
                      "--input", "-p", "--preview", "--cache"],
           "booleans": ["-i", "--include", "--paginate", "--slurp",
                        "--silent", "--verbose", "--allow-escape-sequences"] }
}
```
(flags from `gh api --help`.)

`curl`: take `o`, `output`, `D`, `dump-header` out of the ask list into a
second gate:
```json
{ "options": ["o", "output", "D", "dump-header"],
  "not": [{ "option_values": { "options": ["o", "output", "D", "dump-header"],
                               "values": ["/dev/null", "-"] } }] }
```
Add `arity` `"*"` hints (from `curl --help all`): takers `-o --output -D
--dump-header -w --write-out -H --header -A --user-agent -e --referer -u
--user -m --max-time --connect-timeout --retry -b --cookie -X --request`;
booleans `-s --silent -S --show-error -L --location -f --fail -I --head -i
--include -k --insecure -v --verbose -G --get --compressed`.

### 5. `~/dotfiles/config/claude/settings.json`
Remove `Bash(gh api *)` from allow and the five `Bash(gh api …)` asks.

### 6. Tests
`permission_rules.test.lua` (end to end, `should_auto_approve`):
- approve: `gh api -X GET /x -f q=1`, `gh api -XGET /x`,
  `gh api --method=GET /x -f q=1`, `gh api /x` (unchanged),
  `curl -sS -o /dev/null -w '%{http_code}' https://x`, `curl -D - https://x`
- prompt: `gh api -X GET /x -X DELETE`, `gh api -X GET --method POST /x`,
  `gh api /x -f q=1`, `gh api /x --raw-field q=1`,
  `gh api -X GET /x -F a=@/etc/passwd`, `gh api -X $m /x`,
  `gh api -X=GET /x` (getopt reading `=GET`), `gh api --meth GET /x`,
  `gh api -X get /x`, `curl -o /dev/null -o out https://x`,
  `curl -o out https://x`
- Replace the "asks gh api -X GET (value-blind method gate)" case and its
  comment.

`permission_structured.test.lua`:
- `OptionParse.value` per form: `--name=v`, hinted/unhinted `--name`,
  cluster with booleans then taker, `-X=GET`, taker as last word, unhinted
  letter first.
- `gate_may`/`gate_must` via `decide_leaf`/`classify_leaf`: nested `not`,
  a dynamic token inside a `not` (ask fires), an unhinted flag that may
  absorb the gated option (ask fires).
- `normalise_gate`: malformed `option_values` on ask drops the `not` list;
  on allow drops the gate; `not` on deny is dropped with a warning.

### 7. Docs
- `doc/agentic.txt` structured rules: one sentence each for `not` and
  `option_values`, and that deny gates do not take them.
- `permissions` skill: one line in § Shell command parsing naming the two
  fields and the may/must reading; `references/parsing.md` a short
  § Gate conditions with the may/must rules and the deny exclusion.

## Expected outcome
- `gh api -X GET search/issues -f q=x -f per_page=20 --jq …` auto-approves.
- `gh api` writes (`-X POST`, `-f` without `-X GET`, `--raw-field`,
  `--field`, `--input`, `-F`) prompt; `--raw-field` and `--field` no longer
  classify `read_only`.
- `curl -o /dev/null` and `curl -D -` inside compound commands
  auto-approve.
- Outside agentic.nvim, every `gh api` prompts.
- The user's original command, `gh api … -f q="repo:… $q"`, still prompts:
  `option_values_must` fails on any dynamic word in the leaf (see
  Non-goals).

## Non-goals
- Dynamic tokens. 2,574 of the 3,613 ask-fired leaves in the scan have a
  dynamic token. A quoted `"…$q"` is one word, so as the value of a hinted
  taker it cannot be an option, but `ParsedLeaf` does not mark single-word
  tokens. Separate plan.
- Deny-gate conditions (see Background).
- Other value/combination carve-outs the fields enable: `curl -G` with
  `-d` (needs a `@file` value exception), `zsh -n`, `print -u 1|2`,
  `git -c user.*`.
- curl write options missing from the ask list (`-c`/`--cookie-jar`,
  `--libcurl`, `--etag-save`, `--stderr`, `--hsts`, `--alt-svc`): see
  `notes/bug-curl-unlisted-write-options.md`.

## Open questions
None.
