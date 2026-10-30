# Plan: value and negation conditions on structured gates
Status: reviewed spec

## Relevant files
- `lua/agentic/utils/permission_structured.lua` — `PermGate`,
  `arity_kinds`, `option_takes_next`, `sure_identifiers`,
  `flag_candidates`, `ExistCtx`, `build_exist_ctx`, `ForallCtx`,
  `build_forall_ctx`, `gate_matches_existential`, `gate_matches_universal`,
  `decide_leaf`, `classify_leaf`, `deny_leaf`
- `lua/agentic/utils/option_parse.lua` — new, with `option_parse.test.lua`
- `lua/agentic/utils/permission_rules.lua` — `normalise_gate`,
  `normalise_structured_entries`
- `lua/agentic/permissions.json` — `gh`, `curl`
- `~/dotfiles/config/claude/settings.json` — the `gh api` allow and asks
- Tests: `lua/agentic/utils/{permission_structured,permission_rules}.test.lua`
- Docs: `doc/agentic.txt` structured-rules paragraph (under
  `permissions.structured`); `permissions` skill `SKILL.md` § Shell command
  parsing, `references/parsing.md` § Arity — absorption parses
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

A transcript scan found more of the same shape: `curl -G` with `-d`,
`zsh -n`, `print -u 1|2`, `git -c user.*`.

A general if/else tree per entry was considered. Rejected: in a first-match
tree, an allow branch put before its ask branch approves the write, and
users add rules through `Config.permissions.structured`. The fixed
precedence deny > ask > allow makes an ordering mistake only over-prompt.
The chosen design keeps the precedence and adds boolean structure inside a
gate:

- `unless: PermGate[]` — the gate holds only if none of the listed gates
  hold. With the existing AND of a gate's fields and OR of a kind-array,
  this gives full propositional logic. (`not` is a Lua keyword.)
- `option_values: { options, values }` — some listed option occurs, and
  every occurrence of any listed option has a value that matches a glob in
  `values`. The options are one group, so `-X GET --method POST` fails.

**Evaluation under ambiguity.** A leaf has several parses (unhinted arity,
dynamic tokens). Each gate gets two readings: `may` (holds in some parse;
over-approximates) and `must` (holds in every parse; under-approximates).
The existing existential matcher is `may` of the plain fields, and the
universal matcher is `must`. `unless` swaps them:
`may(unless g) = ¬must(g)`, `must(unless g) = ¬may(g)`. Ask fires on
`may`, allow approves on `must`, so an unclear condition prompts. A present
wrong arity hint can now suppress an ask, not only approve via allow.

**Deny gates do not take the new fields.** `deny_leaf` is concrete-only (a
dynamic token never fires deny) and rejects with no prompt.
`may(unless g)` there would be `¬must(g)`, which a dynamic token makes
true, so a dynamic token would fire a hard reject.

**Parsing is a separate layer.** How a word delivers a value to an option
(`-X GET`, `-XGET`, `-X=GET`, `--method GET`, `--method=GET`, a cluster
`-iXGET`) is read by `option_parse.lua`. The decision layer in
`permission_structured.lua` consumes only `{id, values}` records and the
globs.

**settings.json blocks the change.** It has `Bash(gh api *)` in allow and
`Bash(gh api *-X*)`, `*--method*`, `*-f*`, `*-F*`, `*--input*` in ask. The
glob layer votes ask on `-X GET`, so the structured change has no effect
while they exist. Removing only the asks lets the SDK auto-approve
`gh api -X DELETE` in every Claude session. So all six lines go; `gh api`
then reaches the plugin as an SDK `ask`. A session outside agentic.nvim
prompts for every `gh api`.

**Existing hole.** The structured `gh api` ask lists `f` and `F` but not
`raw-field` and `field`: `gh api /x --raw-field a=b` (a POST) gets
`decide_leaf` "allow" today. Only the settings.json `*-f*` glob catches
it, so change 4 must land before change 5.

## Changes

### 1. `lua/agentic/utils/option_parse.lua` (new)
Word-level readers that take a `kinds` table. Move from
`permission_structured.lua` with no behaviour change: `option_takes_next`
(as `M.takes_next`) and `sure_identifiers` (as `M.sure_identifiers`). The
`PermArityKind`/`PermTakesNext` aliases move as `agentic.OptionKind`/
`agentic.OptionTakesNext`. `arity_kinds` stays in
`permission_structured.lua` (it resolves the schema's scope keys).

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
--- @param kinds table<string, agentic.OptionKind>
--- @return agentic.OptionValue|nil occurrence nil when no option in the word
---         takes a value, an unhinted option comes first, or a taker is the
---         last word
function M.option_value(word, next_word, kinds)
```

### 2. `lua/agentic/utils/permission_structured.lua`
- Require `option_parse`; replace the moved helpers' call sites.
- `PermGate` gains `unless?: agentic.PermGate[]` and
  `option_values?: agentic.PermOptionValues`:
  ```lua
  --- @class agentic.PermOptionValues
  --- @field options string[] dashless identifiers, one group
  --- @field values string[] globs a value must match
  ```
- Replace `flag_candidates` with
  `local function flag_indices(words, dashdash_value) -> integer[]`: the
  indices of `is_flag` words before the first `ends_options`.
  `ExistCtx` gains `flag_idx: integer[]`; `flag_cands` is derived from it.
  Both readers share this one loop.
- `ForallCtx` gains `word_values: table<integer, agentic.OptionValue>`. In
  `build_forall_ctx`, for each options word (the existing `options_word`
  test), call `OptionParse.option_value(words[i], words[i + 1], kinds)` for
  every reaching state's kinds; store it only when all states give the same
  `id` and values.
- New decision functions:
  ```lua
  --- Whether `cond` holds in every parse. False when the leaf has a dynamic
  --- word. Hits are the words at `exist.flag_idx` whose
  --- `extract_option_candidates` match `cond.options`. True iff there is a
  --- hit and every hit has a `forall.word_values` entry whose `id` is in
  --- `cond.options` exactly and whose every candidate value matches a glob
  --- in `cond.values`.
  local function option_values_must(cond, exist, forall) -> boolean

  --- Whether `cond` may hold: `match_options(exist.flag_cands,
  --- cond.options)` or `exist.has_dynamic`. Values are not read.
  local function option_values_may(cond, exist) -> boolean

  --- `gate_matches_existential` ∧ `option_values_may` ∧
  --- every `unless` gate fails `gate_must`.
  local function gate_may(gate, exist, get_forall) -> boolean

  --- `gate_matches_universal` ∧ `option_values_must` ∧
  --- every `unless` gate fails `gate_may`.
  local function gate_must(gate, exist, get_forall) -> boolean
  ```
  `get_forall` builds the `ForallCtx` on first call and caches it; deny
  never calls it.
- `decide_leaf`: ask uses `gate_may`, allow uses `gate_must`. Deny keeps
  `gate_matches_existential`.
- `classify_leaf`: same substitution for ask and the allow kinds.
- `deny_leaf`: no change.

### 3. `lua/agentic/utils/permission_rules.lua` — `normalise_gate`
```lua
--- @param gate any
--- @param kind agentic.PermKind
--- @param depth integer nesting level of `unless`; over 8 is a defect
--- @return agentic.PermGate|nil gate nil when the gate is dropped
--- @return boolean defect the gate or its `unless` subtree had a defect
local function normalise_gate(gate, kind, depth)
```
A defect is: an unknown key; a field of the wrong type; an
`option_values` whose `options` or `values` is not a non-empty list of
strings; an `unless` child that is not a table or normalises to `{}`; a
defect in any `unless` child; depth over 8 (a cyclic user table). On a
defect, with a `Logger.notify` WARN naming the command:
- ask gate: keep the plain fields, drop `option_values` and the whole
  `unless` list (the gate widens: more prompts);
- allow gate: drop the gate;
- deny gate: `unless` and `option_values` are always a defect; keep the
  plain fields (the reject widens).
Today an unknown key is dropped silently; on an allow gate this widens
the approval (a typo `"Unless"`), so the allow rule closes that too.

### 4. `lua/agentic/permissions.json`
`gh`:
```json
"ask": [
  { "positionals": ["api"],
    "options": ["X", "method", "f", "raw-field"],
    "unless": [{ "option_values": { "options": ["X", "method"],
                                    "values": ["GET"] } }] },
  { "positionals": ["api"],
    "options": ["F", "field", "input", "hostname"] },
  { "positionals": ["api", "graphql"], "options": ["f", "raw-field"] },
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
(Flags from `gh api --help`. The `graphql` gate: whether GitHub runs a
mutation sent over GET is not known, so it keeps prompting.)

`curl`: take `o`, `output`, `D`, `dump-header` out of the ask list into a
second gate (`expand-output` and `expand-dump-header` stay in the main
list):
```json
{ "options": ["o", "output", "D", "dump-header"],
  "unless": [{ "option_values": { "options": ["o", "output", "D", "dump-header"],
                                  "values": ["/dev/null", "-"] } }] }
```
Add `arity` `"*"` hints (from `curl --help all`): takers `-o --output -D
--dump-header -w --write-out -H --header -A --user-agent -e --referer -u
--user -m --max-time --connect-timeout --retry -b --cookie -X --request`;
booleans `-s --silent -S --show-error -L --location -f --fail -I --head -i
--include -k --insecure -v --verbose -G --get --compressed`.
`--output /dev/null` still prompts: the candidate `output` prefix-matches
`output-dir`, which stays in the main ask list.

### 5. `~/dotfiles/config/claude/settings.json`
Remove `Bash(gh api *)` from allow and `Bash(gh api *-X*)`,
`Bash(gh api *--method*)`, `Bash(gh api *-f*)`, `Bash(gh api *-F*)`,
`Bash(gh api *--input*)` from ask.

### 6. Tests
`permission_rules.test.lua` (end to end, `should_auto_approve`):
- approve: `gh api -X GET /x -f q=1`, `gh api -XGET /x`, `gh api -iXGET /x`,
  `gh api --method=GET /x -f q=1`, `gh api /x` (unchanged),
  `curl -sS -o /dev/null https://x`,
  `curl -sS -o/dev/null https://x`, `curl -D - https://x`
- prompt: `gh api -X GET /x -X DELETE`, `gh api -X GET --method POST /x`,
  `gh api -X GET -H -- -X POST /x`, `gh api /x -f q=1`,
  `gh api /x --raw-field q=1`, `gh api /x --field q=1`,
  `gh api -X GET /x -F a=@/etc/passwd`, `gh api -X $m /x`,
  `gh api -X GET /x -X`, `gh api -X=GET /x`, `gh api --meth GET /x`,
  `gh api -X get /x`, `gh api graphql -X GET -f query=x`,
  `curl -o /dev/null -o out https://x`, `curl -o out https://x`,
  `curl --output /dev/null https://x`
- Replace `it("asks gh api -X GET (value-blind method gate)")` and its
  comment.
- `get_structured_entries` with a user rule: a typo key inside an
  `unless` child of an ask gate keeps the ask firing; an empty `unless`
  child does too; a defect on an allow gate drops it; `unless` on deny
  warns and is dropped; a cyclic `unless` warns.

`option_parse.test.lua`: `option_value` per form — `--name=v`,
hinted/unhinted `--name`, cluster with booleans then taker, `-X=GET`,
taker as last word, unhinted letter first.

`permission_structured.test.lua`: `decide_leaf`/`classify_leaf` with a
nested `unless`, a dynamic token inside an `unless` (ask fires), and an
unhinted flag that may absorb the gated option (ask fires).

### 7. Docs
- `doc/agentic.txt` structured rules: one sentence each for `unless` and
  `option_values` (a `*` in a value glob crosses `/`), and that deny
  gates do not take them. The existing "a wrong hint can auto-approve a
  write" stays.
- `permission_structured.lua` module docstring and `parsing.md` § Arity —
  absorption parses: amend the "deny/ask are existential, an over-match
  only over-prompts / needs no arity table" statements in place — an
  `unless` reads `must`, so a present hint can suppress an ask.
- `permissions` skill SKILL.md: one line in § Shell command parsing naming
  the two fields and the may/must reading.
- Limit, next to the `option_values` doc: a single-letter long word
  (`--m`) is read as a short option, so a getopt_long abbreviation of a
  listed long option is not a hit. Not reachable for `gh` (pflag) or
  `curl` (exact names from 8.6; before, `--o` and `--d` are ambiguous).

## Expected outcome
- `gh api -X GET search/issues -f q=x -f per_page=20 --jq …` auto-approves.
- `gh api` writes (`-X POST`, `-f` without `-X GET`, `--raw-field`,
  `--field`, `--input`, `-F`, graphql with `-f`) prompt; `--raw-field` and
  `--field` no longer classify `read_only`.
- `curl -o /dev/null` and `curl -D -` inside compound commands
  auto-approve; `curl --output /dev/null` still prompts.
- Outside agentic.nvim, every `gh api` prompts.
- `gh api … -f q="repo:… $q"` still prompts: `option_values_must` fails on
  any dynamic word in the leaf (see Non-goals).

## Non-goals
- Dynamic tokens. Most ask-fired leaves in the scan have one. A quoted
  `"…$q"` is one word, so as the value of a hinted taker it cannot be an
  option, but `ParsedLeaf` does not mark single-word tokens. Separate
  plan.
- Deny-gate conditions (see Background).
- The other carve-outs the fields enable (`curl -G`, `zsh -n`,
  `print -u`, `git -c`).
- A value-aware `curl -w` carve-out: it needs `option_values_may` to read
  values.

## Open questions
None.
