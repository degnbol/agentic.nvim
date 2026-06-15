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

**Decision: introduce a structured matcher over the tokenised `command` node.**
Tree-sitter gives clean token boundaries (through quoting, whitespace,
operators) that the glob cannot. It does *not* give getopt semantics (it will
not expand `-uo` → `-u -o` or bind `-o`'s argument). We do not need the
semantics — only flag *presence*, and over-approximating presence is sound for
deny/ask:

- single-dash token `-uo` → candidate flags = letter-set `{u, o}` AND long-name
  `uo` (find-style single-dash long flags like `-okdir`, `-exec`).
- double-dash token `--output=x` → long-name `output`, prefix-matched (catches
  GNU abbreviations `--out`).
- quote-stripped `string`/`raw_string` tokens are candidates too
  (`sort "-o" out`).
- An entry's `options` field matches if any candidate hits.

Adding spurious candidates (glued-arg chars, the wrong cluster interpretation)
can only make more deny/ask rules fire — never miss a real deny flag. So `-o`,
`-oFILE`, `-uo`, `--output`, `--out=` are all caught. Cost is occasional
over-prompting (incompleteness-safe).

### Architecture: two layers, complementary

`~/.claude/settings.json`, `.claude/settings.json`, and `Config.permissions.*`
use Claude's `Bash(...)` glob format. Shared with the Claude TUI — the glob
schema cannot change there. So the **glob layer stays** for user-side rules,
unchanged.

The plugin's bundled defaults migrate fully. **`permissions.json` becomes
purely structured** — no mixed file, no residual glob sections. The structured
schema is plugin-internal and not constrained by Claude's format.

Per leaf (extracted by the walker), the two layers compose:

```
approve  iff  (glob_allow OR structured_allow)
        AND NOT (glob_deny OR structured_deny OR glob_ask OR structured_ask)
```

Allow is union (either layer authorises). Deny/ask is OR (either layer
vetoes). The user's settings.json carries familiar `Bash(...)` patterns. The
plugin's structured layer carries cluster-proof rules for flag-writers, plus
the migrated bundled allowlist.

### Structured schema

`permissions.json` is a flat list of entries. Each entry names a command and
carries up to three gates (`allow`, `ask`, `deny`). Each gate has a uniform
shape:

```jsonc
[
  { "cmd": "find",
    "allow": {},
    "deny":  { "options": ["exec", "execdir", "okdir", "delete", "ok"] } },

  { "cmd": "sed",
    "allow": {},
    "deny":  { "options": ["i"] } },

  { "cmd": "yq",
    "allow": {},
    "ask":   { "options": ["i"] } },

  { "cmd": "gh",
    "allow": {},
    "ask":   { "positionals": ["api"],
               "options":     ["X", "method", "f", "F", "input"] } },

  { "cmd": "pdftotext",
    "allow": { "positionals": ["*.pdf", "-"] } },

  { "cmd": "git",
    "allow": { "positionals": ["diff"] },
    "category": "read_only" },

  { "cmd": "mlr",
    "allow": {},
    "deny":  { "options": ["I"] },
    "category": "safe_write" },

  { "cmd": "*",
    "allow": { "options": ["help", "version"] } }
]
```

Fields per entry:

- **`cmd`** (required) — literal command name (after `strip_command_path`), or
  `"*"` for cross-command rules. Only exact `*` is meaningful; no other glob
  shape on `cmd`.
- **`category`** (optional, default `"read_only"`) — `"read_only"` or
  `"safe_write"`. Mirrors the existing user-facing `auto_approve` toggle:
  `auto_approve = "read-only"` filters out `category: "safe_write"` allow
  gates; `auto_approve = "allow"` accepts both; `auto_approve = nil` rejects
  all allow gates. Deny and ask gates are unconditional (a `safe_write` entry
  with a deny gate still vetoes even at `auto_approve = nil`).
- **`allow`** / **`ask`** / **`deny`** (each optional) — gate spec. A gate
  shape:

  ```jsonc
  { "options":     ["help"],              // optional; literal flag names
    "positionals": ["config", "--get"] }  // optional; literal or glob
  ```

  An empty gate `{}` matches the bare command (no further constraints). Any
  field present must match.

Gate-field semantics:

- **`options`** — list of flag identifiers (short letters or long names). A
  candidate set is built from every literal arg token via the cluster
  expansion above; the gate matches if any candidate is in the list.
  **Literal identifiers only — no globs.** A glob on a flag id would reabsorb
  the cluster leak this layer exists to close (`-uo` would no longer expand to
  `{u, o}`).
- **`positionals`** — array of patterns matched in order against the
  positional arg list (after the option walker skips leading options + their
  consumed values per `OPTION_VALUE_TAKERS`). The first element matches the
  first non-option token — whatever role the command treats it as (subcommand,
  file path, …). Trailing positionals are allowed beyond the array's length,
  so `positionals: ["push"]` matches `git push --foo bar`. Literal or glob
  per element. `git -C path config --get foo` resolves to positionals
  `["config", "--get", "foo"]` (the `-C path` pair is consumed by the option
  walker), which `["config", "--get", "*"]` matches.

Where glob is and is not allowed inside the schema:

| Field | Glob? |
| --- | --- |
| `cmd` | only exact `"*"` |
| `positionals[i]` | yes |
| `options[i]` | no — literal flag identifiers |

Glob syntax is the same `*` as Claude's `Bash(...)` patterns (also used by the
existing glob layer).

### Entry composition

Multiple entries can match the same command — for example "allow `find`, deny
`find -exec`" as two separate entries, or rolled into one entry's two gates.
Per leaf, collect every matching entry's gates. Within a leaf:

- **deny** if any matched deny gate fires;
- else **ask** if any matched ask gate fires;
- else **allow** if any matched allow gate fires (subject to the `category`
  filter against `auto_approve`);
- else fall through to the glob layer.

The composition rule at the top (`approve iff (glob OR structured) ALLOW
AND NOT any DENY/ASK`) is just this per-layer result combined.

### Matcher API spec

This section pins down the public API, algorithms, and data-shape contracts
of `lua/agentic/utils/permission_structured.lua`. It is authoritative; where
it diverges from the test corpus at `permission_structured.test.lua`, the
test will be adjusted in chunk 5.

#### Module shape and types

```lua
--- @class agentic.utils.PermissionStructured
local M = {}
```

`StructuredEntry` mirrors the JSON schema in § Structured schema. Optional
fields are absent (not `vim.NIL`) when unspecified — `cjson.decode` of
`permissions.json` already produces this shape.

```lua
--- @alias agentic.PermCategory "read_only" | "safe_write"
--- @alias agentic.PermAutoApprove "allow" | "read-only" | nil
--- @alias agentic.PermDecision "allow" | "ask" | "deny" | nil

--- @class agentic.PermGate
--- @field options?     string[] -- literal flag identifiers, no globs
--- @field positionals? string[] -- per element literal or glob

--- @class agentic.StructuredEntry
--- @field cmd       string      -- literal cmd name or exact "*"
--- @field allow?    agentic.PermGate
--- @field ask?      agentic.PermGate
--- @field deny?     agentic.PermGate
--- @field category? agentic.PermCategory  -- default "read_only"

--- @class agentic.ParsedLeaf
--- @field cmd_name string    after strip_command_path / wrapper strip
--- @field args     string[]  quote-stripped, env-prefix/redirect-excluded

--- @class agentic.ResolvedArgs
--- @field positionals   string[]    non-option tokens, in source order
--- @field option_tokens string[]    leading option tokens + consumed values
```

The walker is the sole producer of `ParsedLeaf` (chunk 3). The matcher
trusts its input.

#### Public functions

```lua
--- Build the set of option-identifier candidates for a single token.
--- Over-approximates: extra candidates can only widen deny/ask matches,
--- never miss a real one (see Phase 1b § soundness argument).
--- @param token string
--- @return string[]  candidates  -- possibly empty
function M.extract_option_candidates(token) end

--- True iff any element of `candidates` matches any element of
--- `rule_options` under the asymmetric prefix rule (see below).
--- @param candidates   string[]
--- @param rule_options string[]
--- @return boolean
function M.match_options(candidates, rule_options) end

--- Split args into leading option tokens (consuming arg-taking-global
--- values per `OPTION_VALUE_TAKERS`) and the remaining positional tokens.
--- A bare `--` terminates the option block. The first positional is
--- whatever role the command treats it as — gates always match it via
--- `positionals[1]`, so the matcher has one uniform concept.
--- @param args     string[]
--- @param cmd_name string
--- @return agentic.ResolvedArgs
function M.resolve_args(args, cmd_name) end

--- Collect every matching entry's gates and resolve deny > ask > allow,
--- with allow gated by the category filter.
--- @param entries      agentic.StructuredEntry[]
--- @param parsed       agentic.ParsedLeaf
--- @param auto_approve agentic.PermAutoApprove
--- @return agentic.PermDecision
function M.decide_leaf(entries, parsed, auto_approve) end
```

Internal helpers (not exported, named so reviewers can grep):
`gate_matches`, `positionals_match`, `allow_category_ok`,
`collect_option_candidates`, `match_one`. None are called by the test
file; the public four cover every assertion in
`permission_structured.test.lua`.

#### Cluster expansion algorithm

Input contract: the walker has already quote-stripped `string` and
`raw_string` tokens. Concatenations like `--foo"="bar` are joined into a
single literal before reaching the matcher; a concatenation that contains
a non-literal child causes the walker to bail (see chunk 3), so we never
see a partially-quoted form here.

```text
extract_option_candidates(token):
    1. If token == "" → return {}.
    2. If token does not start with "-" → return {} (positional).
    3. Long-only =value strip:
         If token starts with "--" and contains "=" at position p >= 3:
             head = token[1..p-1]    -- drop the =value suffix
         else:
             head = token            -- short tokens keep their body
    4. End-of-options / stdin sentinels:
         If head == "-"  → return {}.
         If head == "--" → return {}.
    5. Long-flag branch (head starts with "--"):
         name = head[3..]            -- strip the leading "--"
         If name == ""   → return {} -- handles "--=value"
         return { name }
    6. Short-flag branch (head starts with "-", does not start with "--"):
         body = head[2..]            -- strip the leading "-"
         If body == "" → return {}   -- already handled by step 4
         letters = { each character of body, in order }
         long    = body
         return dedup(letters ++ { long })
```

Worked examples (every case is a test in `extract_option_candidates`):

| Token | Steps fired | Output |
| --- | --- | --- |
| `-uo` | 2, 6 | `{"u", "o", "uo"}` |
| `--output=x` | 2, 3, 5 | `{"output"}` |
| `--out=x` | 2, 3, 5 | `{"out"}` |
| `-oFILE` | 2, 6 | `{"o", "F", "I", "L", "E", "oFILE"}` |
| `-o` (any source) | 2, 6 | `{"o"}` |
| `--` | 2, 4 | `{}` |
| `-` | 2, 4 | `{}` |
| `--=value` | 2, 3, 5 (name empty) | `{}` |
| `-=x` | 2, 6 | `{"=", "x", "=x"}` |
| `file.txt` | 2 | `{}` |
| `""` | 1 | `{}` |

Step 3 fires when `=` is at position `≥ 3` (the first character after
the leading `--`). `--=value` strips its `=value` suffix to just `--`,
which step 4 then rejects as the end-of-options sentinel. Step 3 runs
only for `--`-prefixed tokens — no real CLI defines a single-letter
option that takes an `=value` form, and the over-approximate
short-cluster expansion still matches the deny rule for any plausible
`-o=x` usage. Determinism: `letters` follows source token order,
`dedup` preserves first occurrence, long-name candidate is appended
last.

#### Option matching rule

Asymmetric prefix:

> A candidate `c` matches a rule option `r` iff `r:sub(1, #c) == c` —
> i.e. **the candidate is a (possibly improper) prefix of the rule
> option**. Letters are the `#c == 1` special case of the same rule.

Justification: GNU long-option abbreviation lets users type `--out`
when the program advertises `--output`. The candidate is the user's
typed prefix; the rule lists the canonical long name. The reverse
direction (rule `out`, candidate `output`) would over-fire — denying
`--out` would silently deny `--output`, `--outfile`, `--outer-join`.
Test `does not match a long-name candidate when the rule is the prefix`
pins this direction.

The single-letter case needs guarding: under a naive prefix rule,
`{"o"}` vs `{"output"}` would match (`r:sub(1, 1) == "o"`). Resolution:
the prefix rule applies *only when both sides have length ≥ 2*; for
single-letter candidates only exact equality counts. Combined:

```lua
local function match(c, r)
    if #c == 1 then return c == r end
    return r:sub(1, #c) == c
end
```

This satisfies every assertion in `describe("match_options")`.
`match_options(cands, rule)` is `any(cand) any(r) match(cand, r)`;
empty `cands` or empty `rule` returns false.

#### Rule option normalisation (load-time)

`permissions.json` and `Config.permissions.structured` entries should be
readable as configuration. A rule deny on the `--output` flag is more
recognisable as `options: ["--output"]` than as `options: ["output"]`. The
matcher canonicalises both forms to the dashless candidate space by stripping
leading dashes at rule-load time:

```lua
-- in get_structured_entries (chunk 6 implementation)
local function normalise_option(s)
    return (s:gsub("^%-+", ""))
end
```

Applied once per option per entry as part of pattern compilation, alongside
`glob_to_lua_pattern` on positional fields. Idempotent — a rule already
written as `"exec"` is unchanged.

After normalisation:

| Rule input | Stored as | Matches candidate(s) |
| --- | --- | --- |
| `"exec"`   | `"exec"`   | long-name `exec` from `-exec`, `--exec`, `-ex"e"c` (concat-eval) |
| `"-exec"`  | `"exec"`   | same |
| `"--exec"` | `"exec"`   | same |
| `"o"`      | `"o"`      | letter `o` from `-o`, `-uo`, `-oFILE` |
| `"-o"`     | `"o"`      | same |

This is a documentation convenience only — the matcher's internal candidate
space remains dashless, and the comparison rule above is unchanged. Test
coverage for the normalisation lives in chunk 6's `get_structured_entries`
test (not in `permission_structured.test.lua`, which works on already-loaded
entries).

#### Arg resolution (`resolve_args`)

Per-command option-value-takers — option flags that consume the next
token as their argument. The option walker uses this table to keep
`-C path` together when separating leading options from positionals.
Built from an audit of the current `permissions.json` entries that pass
an option before the first positional:

```lua
--- @type table<string, table<string, true>>
local OPTION_VALUE_TAKERS = {
    git = {
        ["-C"]             = true,  -- run as if started in <path>
        ["-c"]             = true,  -- one-shot config: -c key=value
        ["--git-dir"]      = true,  -- path to .git
        ["--work-tree"]    = true,  -- path to working tree
        ["--namespace"]    = true,  -- ref namespace
        ["--exec-path"]    = true,  -- path to git core
        ["--super-prefix"] = true,  -- submodule super-prefix
    },
    gh = {
        ["-R"]         = true,  -- repo slug
        ["--repo"]     = true,  -- repo slug
        ["--hostname"] = true,  -- GH host
    },
    aws = {
        ["--region"]              = true,  -- region name
        ["--profile"]             = true,  -- credential profile
        ["--endpoint-url"]        = true,  -- override service endpoint
        ["--output"]              = true,  -- json/text/table
        ["--cli-binary-format"]   = true,  -- raw-in-base64-out / etc.
        ["--ca-bundle"]           = true,  -- path to CA bundle
        ["--cli-read-timeout"]    = true,  -- seconds
        ["--cli-connect-timeout"] = true,  -- seconds
    },
    flytectl = {
        ["--config"]         = true,  -- path to config file
        ["--admin-endpoint"] = true,  -- admin endpoint URL
    },
}
```

Justification per command:

| Command | Why these entries? |
| --- | --- |
| `git` | Patterns like `Bash(git -C * rev-parse *)` exist today. `-C` takes a path, `-c key=value` takes the assignment as one token, `--git-dir`/`--work-tree`/`--namespace`/`--exec-path`/`--super-prefix` all take a path. Every other top-level option (`--bare`, `--version`, `--paginate`, `-p`/`-P`, etc.) is a boolean. |
| `gh` | `gh -R owner/repo issue list` is a common form. `-R`/`--repo`/`--hostname` consume a value; `--help`/`--version` do not. |
| `aws` | The current `Bash(aws * get-*)`, `describe-*`, `list-*`, `head-*` patterns use `*` precisely to swallow `--region foo --profile bar` prefixes. Eight global options take a value (per the aws CLI config-options docs). Booleans like `--no-paginate`, `--no-sign-request`, `--no-verify-ssl`, `--debug` do not. |
| `flytectl` | `Bash(flytectl get *)` is in safe_write. Users routinely prefix `--config ~/.flyte/config.yaml`. Two arg-taking globals matter. |

**Not in the table.** conda, npm, pip / uv pip, brew, pacman (`-Q`,
`-S`, `-R` are themselves the dispatch token), kitty (`@` is a literal
positional, not a global to skip), hyprctl, systemctl, claude. None
have an existing permissions.json pattern that consumes a global option
before the first positional. Add later if migration surfaces a need.

Algorithm:

```text
resolve_args(args, cmd_name):
    globals = OPTION_VALUE_TAKERS[cmd_name] or {}
    i = 1
    option_tokens = {}
    -- Walk past leading options + their arg-taking-global values.
    while i <= #args do
        tok = args[i]
        if tok == "--" then
            i = i + 1            -- consumed; rest is positional
            break
        elseif tok:sub(1, 1) == "-" then
            append option_tokens, tok
            if globals[tok] then
                if args[i+1] ~= nil then
                    append option_tokens, args[i+1]
                    i = i + 2
                else
                    i = i + 1    -- malformed, no value follows
                end
            else
                i = i + 1
            end
        else
            break                -- first positional reached
        end
    end

    positionals = slice(args, i, #args)   -- everything from i onward
    return {
        positionals   = positionals,
        option_tokens = option_tokens,
    }
```

Key properties:

- The matcher has one uniform concept: `positionals[k]` matches the
  k-th non-option token. Whatever the command treats the first
  positional as (subcommand, file path, …) is the rule author's
  concern; the matcher does not distinguish.
- For `cmd_name` not in the table (`globals = {}`), every leading
  option token is consumed individually with no value grab. Same
  algorithm, just no `i + 2` branch.
- `option_tokens` contains the leading option tokens **plus** the
  consumed values of arg-taking globals, in their original order
  (raw token list, no joining). `gh api -X POST` parses as
  `option_tokens = []`, `positionals = ["api", "-X", "POST"]` —
  the `-X` is post-positional and stays in `positionals`. The
  option-candidate collector picks it up there (next section).

#### Gate evaluation

Within a single gate (`agentic.PermGate`):

```text
gate_matches(gate, resolved, opt_cands):
    if gate.options ~= nil then
        if not match_options(opt_cands, gate.options) then
            return false
        end
    end
    if gate.positionals ~= nil then
        if not positionals_match(gate.positionals, resolved.positionals)
            then return false end
    end
    return true
```

- `opt_cands` is the union of `extract_option_candidates(t)` over
  every token in `resolved.option_tokens` AND every token in
  `resolved.positionals` whose first byte is `-`. Options after the
  first positional still count — `gh api -X POST` has `-X` in
  `positionals`, but a rule listing `X` must match.
- `positionals_match(patterns, positionals)` matches each pattern
  against the same-indexed positional via `glob_to_lua_pattern`.
  Trailing positionals beyond the pattern list are allowed.
  Implementation:

```text
positionals_match(patterns, positionals):
    if #patterns > #positionals then return false end
    for k = 1, #patterns:
        if not lua_match(positionals[k], compile(patterns[k])) then
            return false
        end
    return true
```

This handles the `git push --foo bar` corpus (positionals=`["push",
"--foo", "bar"]`, pattern `["push"]` matches positionals[1]) and the
`pdftotext *.pdf -` corpus (positionals=`["foo.pdf", "-"]`, pattern
`["*.pdf", "-"]` matches in order). Patterns are 1-indexed against
positionals, with no option-skipping mid-list — a rule that needs to
match a token *after* an option in the middle of positionals would
encode the option literally in the pattern (e.g. `positionals: ["api",
"-X", "POST"]`), though in practice options live on either end.

#### Entry composition and category filter

`decide_leaf(entries, parsed, auto_approve)`:

```text
1. Resolve once:
       resolved  = resolve_args(parsed.args, parsed.cmd_name)
       opt_cands = collect candidates from
                       resolved.option_tokens
                       ++ { t in resolved.positionals : t:sub(1,1) == "-" }

2. Filter entries by cmd:
       relevant = { e in entries
                    : e.cmd == parsed.cmd_name or e.cmd == "*" }

3. For each gate kind in order (deny, ask, allow):
       hits = { e in relevant
                : e[kind] ~= nil
                  and gate_matches(e[kind], resolved, opt_cands)
                  and category_ok(e, kind, auto_approve) }
       (category filter applies only when kind == "allow"; deny/ask
        are unconditional)
       if any hits and kind == "deny"  → return "deny"
       if any hits and kind == "ask"   → return "ask"
       if any hits and kind == "allow" → return "allow"

4. Return nil.

category_ok(entry, kind, auto_approve):
    if kind ~= "allow" then return true end
    cat = entry.category or "read_only"
    if auto_approve == "allow"     then return true end
    if auto_approve == "read-only" then return cat == "read_only" end
    return false           -- auto_approve == nil rejects all allow gates
```

Precedence is therefore **deny > ask > allow**, evaluated across the
*union* of all entries matching `cmd` (literal name or `*`). A deny
gate in one entry vetoes an allow gate in another for the same
command — the `find` / `sort` corpus pins this. A `*` entry's allow
gate fires for any command whose own entries don't deny/ask first,
which is how `Bash(* --help)` migrates.

#### Resolution of `-- AMBIGUOUS:` markers

| # | Marker (test name) | Resolution |
| --- | --- | --- |
| 1 | `returns no candidates for --=value` | **`{}` (no candidates).** Step 5 returns `{}` when the stripped long name is empty. The locked test asserts `{}`; this spec confirms it. Empty-string candidates would never match any real rule, so the conservative path is observationally identical — pick the conservative one for cleanliness. No test change. |
| 2 | `emits a single-char letter set for -=x` | **`{"=", "x", "=x"}`** via the short-flag branch. The `=value` strip in step 3 only runs when the head starts with `--`, so `-=x` keeps the full `=x` as the cluster body. `=` is a harmless candidate (no rule lists it). Matches the locked test. No test change. |
| 3 | `skips git's -C <path>` — `option_tokens` shape | **Raw token list `("-C", "path")`.** Two reasons: (a) downstream `match_options` only consumes option tokens — the value token never participates in the candidate set, but keeping it in the list preserves token-position invariants for future code (e.g. a hypothetical "deny `-c key=value` where key matches X" rule); (b) joining to `"-C path"` would silently invert the no-quoting-needed property the walker established. Matches the locked test. No test change. |

No test-corpus assertions need to be edited as a result of these
resolutions.

#### Out of scope for the matcher

Quote handling, concatenation, command substitution, and `file_redirect`
classification all bail upstream in the walker. The matcher trusts its
`ParsedLeaf` input. On fall-through `decide_leaf` returns `nil`; the
caller composes the structured result with the glob layer per
§ Architecture.

### Walker integration spec

This section pins down how the existing zsh tree-sitter walker (chunk 3 of the
work-breakdown) feeds the new structured matcher (chunks 1 and 2) in a single
pass. Token extraction, the four-way composition site, and the `WalkCtx` type
change are all locked here so the chunk-6 implementation can land without
re-reading the rest of the plan.

The walker is at `lua/agentic/utils/permission_rules.lua`, lines 485-766.
Node-type names were re-confirmed against the installed `tree-sitter-zsh`
grammar by parsing 17 representative commands (`grep`, `find`, `sort`,
`git -C path config`, `echo a"b"c`, `ls foo${x}bar`, `cat *.txt`, etc.); see
the find-results below.

#### Token extraction from a `command` node

The walker iterates the named children of a `command` node. Today every
non-`command_name`, non-`variable_assignment` child gets its raw text appended
to `args` for glob-layer concatenation. The new structured layer needs the same
children classified by node type so it can decide which strings are positional
arguments and which are flag candidates.

The rules below cover every named child type the parser emits inside a
`command`. Anything not on this list is **unrecognised** and bails the leaf
(same fail-closed posture as the rest of the walker — if a future grammar
upgrade introduces a new node type, it must be reviewed before it can flow
into the structured matcher).

| Child node type | Action |
| --- | --- |
| `command_name` | Single token: `cmd_name`. Goes through `command_name_text` (existing) for quote-strip and dynamic-name rejection, then `strip_command_path` for the system-bindir prefix. No change. |
| `variable_assignment` | Excluded from tokens. Existing `safe_assignment_name` check decides whether the env-prefix is safe. Unchanged. |
| `word` | One token, raw text. |
| `number` | One token, raw text (`echo 42` produces `number` not `word`). |
| `string` (double-quoted) | One token. Concatenate every `string_content` child verbatim; bail the leaf if any other named child appears (matches the existing rule in `command_name_text` — `"$x"`, `"$(foo)"`, `"a${b}c"` all contain non-`string_content` children). |
| `raw_string` (single-quoted) | One token. Strip exactly one leading `'` and one trailing `'`. Body is opaque shell-literal data. |
| `concatenation` | **Evaluate when literal.** If `subtree_has_substitution(node)` returns true, bail the leaf. Otherwise recurse `literal_token` over each named child and concatenate the results (so `-ex"e"c` joins to `-exec`, `{}` joins to `{}`, `cat /etc/"passwd"` joins to `cat /etc/passwd`). See § Concatenation soundness argument below. |
| `brace_expression` | **Evaluate when literal.** If `subtree_has_substitution(node)` returns true, bail. Otherwise emit one token of the node's raw source text (`{1..3}`, `{a,b,c}`, `file{,.bak}` — the unexpanded form). Brace expansion happens shell-side at runtime; the unexpanded text is a superset of any expansion's characters, so cluster expansion still catches dangerous flags hidden behind a brace (`-x{a,b}` cluster-expands to `{x, {, a, ',', b, }}` — letter `x` still matches a rule on `x`). |
| `glob_pattern` | One token, raw text. Glob expansion is deferred to the shell; for matching purposes the unexpanded glob is what we see (`pdftotext *.pdf` produces a `glob_pattern` token `*.pdf` which matches a `positionals: ["*.pdf"]` literal-glob entry). |
| `expansion`, `simple_expansion`, `variable_ref`, `arithmetic_expansion` | Bail the leaf (subset of `DYNAMIC_NAME_TYPES`, already implicitly handled because they appear under `subtree_has_substitution`'s sibling check at the command level). |
| `command_substitution`, `process_substitution` | Already bailed by `subtree_has_substitution` at the top of `walk_command`. Listed here for completeness. |
| `file_redirect`, heredoc/herestring variants | Not seen as a `command` child — they appear under `redirected_statement`, handled by `walk_redirected`. |

The quote-strip rule for `string` and `raw_string` mirrors `command_name_text`
exactly — the same code path the walker already uses to refuse `"rm"` evading
a deny pattern. Reusing it keeps a single point of truth for "what counts as a
literal".

A `concatenation` token aside (handled in § Concatenation soundness below),
**the existing glob-layer `leaf` string is built unchanged.** The structured
layer reads the same tokens through a different lens. No new code path widens
the glob layer's view.

#### Single-pass emission

`walk_command` already loops the named children once. The structured layer
piggybacks on that loop: where the existing code accumulates `args[]`, the new
code also classifies each token into a `ParsedLeaf` shape.

The test corpus in `permission_structured.test.lua` fixes the `ParsedLeaf`
shape (it's the second argument to `decide_leaf`):

```lua
--- @class agentic.utils.PermissionStructured.ParsedLeaf
--- @field cmd_name string             -- post quote-strip + strip_command_path
--- @field args string[]               -- ordered arg tokens (positional + option, raw)
--- @field full string                 -- cmd_name .. " " .. table.concat(args, " ")
```

`args` is intentionally the flat list of arg tokens in source order — option
clustering, `=value` splits, and the arg-taking-globals skip all happen
*inside* the matcher (`resolve_args` + `extract_option_candidates`),
where they're testable in isolation. The walker only decides which strings
make it into the list.

`full` is the same string `leaf` the glob layer matches against today
(`name .. " " .. table.concat(args, " ")`). Computing it once and storing it
on the parsed record avoids a second concatenation pass in the matcher.

Sketch of the modified per-child loop inside `walk_command`:

```lua
local cmd_name           -- after command_name_text + strip_command_path
local args = {}          -- raw text tokens, ordered

for child in node:iter_children() do
    local t = child:type()
    if t == "variable_assignment" then
        if not safe_assignment_name(child, src) then return false end
    elseif t == "command_name" then
        local name = command_name_text(child, src)
        if not name then return false end
        cmd_name = M.strip_command_path(name)
        if CODE_TAKING_BUILTINS[cmd_name] then return false end
    elseif child:named() then
        local tok = literal_token(child, src)   -- new helper, returns nil on bail
        if tok == nil then return false end
        table.insert(args, tok)
    end
end

local leaf = cmd_name
if #args > 0 then leaf = leaf .. " " .. table.concat(args, " ") end

local parsed = { cmd_name = cmd_name, args = args, full = leaf }
```

`literal_token` is the table above in code form. It is recursive: for
`concatenation` it calls itself on each named child and joins the parts. For
`word`/`number`/`glob_pattern` it returns the raw text; for quote-stripped
`string`/`raw_string` it returns the stripped body; for `brace_expression`
without substitution it returns the raw source text; it returns `nil` for any
dynamic-name node type, for `concatenation`/`brace_expression` whose subtree
contains substitution, and for anything else (fail-closed default). It is the
only new helper introduced for this chunk.

The existing extraction via `vim.treesitter.get_node_text(child, src)` is
*replaced*, not duplicated. For `string` and `raw_string` the raw node text
includes the surrounding quotes, which is wrong for both the glob layer
(`"rm"` evading `Bash(rm)`) and the structured layer (the candidate `-o`
behind `"-o"` would otherwise carry quotes). Today the glob layer happens to
tolerate this because patterns are typically `Bash(rm *)` not `Bash(rm)` — but
the documented intent (`command_name_text` strips quotes for a reason) is
that quote-stripped text is the canonical form. Promoting that to the arg
list closes a quiet hole.

#### Composition site

The four-way combine lives at the bottom of `walk_command`, replacing the
current three-line glob check (lines 697-703). Order of evaluation follows the
plan's formula:

```
approve  iff  (glob_allow OR structured_allow)
        AND NOT (glob_deny OR structured_deny OR glob_ask OR structured_ask)
```

Restated as the per-leaf decision sequence:

```lua
-- Cheap denies first — short-circuit before invoking the structured matcher.
if #ctx.deny > 0 and M.matches_any_pattern(leaf, ctx.deny) then
    return false
end
if #ctx.ask > 0 and M.matches_any_pattern(leaf, ctx.ask) then
    return false
end

-- Structured layer: returns "deny" | "ask" | "allow" | nil.
local structured = nil
if #ctx.structured_entries > 0 then
    structured = PermissionStructured.decide_leaf(
        ctx.structured_entries, parsed, ctx.auto_approve
    )
    if structured == "deny" or structured == "ask" then
        return false
    end
end

-- Allow: either layer suffices.
if structured == "allow" then return true end
return M.matches_any_pattern(leaf, ctx.allow)
```

Ordering rationale:
- Glob deny/ask first — they're a single linear scan over pre-compiled Lua
  patterns. Cheap, and an early veto here saves the structured layer's gate
  iteration.
- Structured deny/ask next — the structured layer can fire denies the glob
  layer cannot (cluster-soundness against `-uo`). Same veto semantics: any
  hit bails.
- Both allow layers last. Union: a glob allow suffices, a structured allow
  suffices, neither needs the other to also fire. This matches the plan's
  "allow is union" rule.

`structured == "ask"` is treated identically to a glob ask (return false).
`structured == nil` means "no matching structured entry" — fall through to
the glob allow check.

#### `WalkCtx` shape update

The current alias at line 499:

```lua
--- @alias agentic.utils.PermissionRules.WalkCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[] }
```

Extended:

```lua
--- @alias agentic.utils.PermissionRules.WalkCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.utils.PermissionStructured.Entry[], auto_approve: "allow"|"read-only"|nil }
```

Both new fields are required (no `?`). The matcher reads `auto_approve` for
the category filter; passing `nil` is meaningful (rejects all allow gates).
Reading from `Config.permissions.auto_approve` inside the walker would
re-introduce a `require("agentic.config")` round-trip per leaf — better to
pass it once at `should_auto_approve`'s callsite, alongside the entries list.

`should_auto_approve` constructs the ctx (the call at lines 799-803):

```lua
return walk(root, command, {
    allow = allow,
    deny = M.get_deny_patterns(),
    ask = M.get_ask_patterns(),
    structured_entries = M.get_structured_entries(),
    auto_approve = Config.permissions.auto_approve,
})
```

`M.get_structured_entries()` is the new accessor — same caching shape as
`get_deny_patterns`, returns the entries parsed from `permissions.json` plus
any `Config.permissions.structured` user additions (defined in chunk 4's
migration spec, not this one). The accessor returns `{}` when the bundled
defaults are disabled and no user entries exist, in which case the
composition site's `#ctx.structured_entries > 0` guard skips the matcher
entirely — no-op for users who haven't opted in.

#### Phase 1a regression surface

The tests at `lua/agentic/utils/permission_rules.test.lua:1020-1175` exercise
`should_auto_approve` end-to-end through the `decide()` helper, which stubs
`read_json` so plugin defaults are *not* loaded — only the test's `perms`
table is in scope. After this chunk, `get_structured_entries()` will also
return `{}` under that stub (the bundled `permissions.json` is its only
source until chunk 4 ships the structured form, and even then `decide()`
stubs the read at `read_json`). The composition site's empty-list guard
skips the structured layer, the existing glob path runs unchanged.

Concretely, every existing test in the file must keep passing without
modification:

- `bails on substitution anywhere` (11 cases) — substitution rejection
  happens in `subtree_has_substitution`, untouched.
- `bails on control flow and compound structure` (7 cases) — container
  whitelist is untouched.
- `bails on file-writing and unmodelled redirects` (4 cases) —
  `walk_redirected` is untouched.
- `bails on a parse error (fail-closed)` (2 cases) — same.
- `bails on code-taking builtins even when allowed` — same.
- `bails on a dynamic (arithmetic) command name` — same.
- `normalises a quoted command name for deny matching` — `command_name_text`
  unchanged.
- `approves inert variable assignments` — same.
- `approves an assignment followed by a use` — same.
- `approves a raw string that looks like substitution` — `raw_string`'s
  literal-data treatment is *promoted* to the args list (was already in the
  joined `leaf`); same observable.
- `ignores a trailing comment` — container walk's `comment` skip is
  unchanged.
- `approves a quoted operator as string data` — `string` quote-strip
  unchanged.
- `returns false when the zsh parser is unavailable` — same.

**One subtle change worth flagging.** Today the glob `leaf` is built by
`table.concat` of raw `get_node_text` outputs, so a quoted arg like `"a|b"`
arrives as the literal `"a|b"` (quotes included) and the pattern
`Bash(grep * file)` matches via the surrounding `*`. After this chunk the
same arg lands in `args` as `a|b` (quote-stripped) and the glob `leaf` becomes
`grep a|b file`. The pattern still matches via `*`, the test passes. If
anyone writes a future test that anchors against a literal `"`, that anchor
will need updating. None of the existing 23 walker tests do this — they
either use broad `Bash(cmd *)` patterns or assert false outcomes where the
quote presence is irrelevant.

#### Concatenation soundness argument

The choice for `concatenation` is **evaluate when literal, bail when
substitution-bearing**.

A `concatenation` node is the parser's way of saying "this argument is built
from multiple lexer tokens glued without whitespace": `-ex"e"c` parses as
`concatenation { word "-ex", string "\"e\"", word "c" }`; `/etc/"passwd"` as
`concatenation { word "/etc/", string "\"passwd\"" }`; `"$x"y` as
`concatenation { string "\"$x\"", word "y" }`; `{}` (find's placeholder) as
`concatenation { word "{", word "}" }`.

The key observation: when every leaf of a `concatenation` is a literal
(`word`, `number`, `glob_pattern`, or quote-stripped `string`/`raw_string`),
the joined text is exactly what the shell delivers to the program — there's
no laundering, because there's nothing dynamic to launder. Walking the
subtree and concatenating the literal pieces gives the true argument value.

Three poisoning cases motivate the design and pin the literal-only guard:

1. **Literal concatenation (`find . -ex"e"c rm {} \;`).** Children are all
   literal. The walker joins to `-exec` (and `{}`). The deny gate
   `{cmd: "find", deny: {options: ["exec"]}}` fires via the long-name
   candidate `exec` from cluster expansion. Correctness preserved.
2. **Substitution-bearing concatenation (`"$x"y`, `f"$(rm x)"oo`).** The
   subtree contains `expansion` or `command_substitution`. The walker cannot
   tell what the shell will actually pass to the program — `"$x"` could be
   `-exec`, `/etc/shadow`, or anything else. Bail. `subtree_has_substitution`
   already exists and detects this in one call.
3. **Per-part emission (`option (c)` in the original analysis).** Splitting
   the literal concatenation into separate tokens (`-ex`, `c`) would let
   `-exec` evade the deny rule entirely — the long-name candidate `exec` is
   never reconstructed. **Unsound. Not chosen.**

The literal-only branch is one line — the same `subtree_has_substitution`
helper used at command level — and the recursion into `literal_token` reuses
the existing per-node rules for string/raw_string quote-stripping. No new
substitution detector, no duplication.

`cat /etc/"passwd"` — concatenation `{word "/etc/", string "passwd"}` — joins
to `/etc/passwd` and feeds a positional that no rule in the bundled
`permissions.json` cares about. The `cat` allow gate's empty `{}` matches.
Auto-approves, same as `cat /etc/passwd` would.

The `command_name_text` rule at line 616-618 of `permission_rules.lua` is
*also* relaxed under this design (in chunk 6's implementation, not chunk 3's
spec) — a literal `concatenation` in command-name position resolves to its
joined text rather than bailing. Today `"rm"` (a `string`) is correctly
resolved to `rm`, but `gr"e"p` (a `concatenation`) bails. After this chunk,
`gr"e"p foo file` resolves to command name `grep` and the existing deny rules
apply uniformly. This closes a Phase 1a hole the plan-reviewer flagged.

#### `brace_expression` soundness argument

`echo {1..3}` and `cp file{,.bak}` parse with a `brace_expression` child of
`command`. The shell expands brace expressions to multiple args before the
program runs: `echo {1..3}` becomes `echo 1 2 3`. The walker sees one node
whose raw text is `{1..3}`.

Emitting raw text is sound for deny matching because the unexpanded form is
a character-level superset of any expansion. Specifically:

- **Option side (cluster expansion).** If a brace expression sits in option
  position (`-x{a,b}` would expand to `-xa -xb`, `--out{put,err}` to
  `--output --outerr`), the unexpanded text feeds `extract_option_candidates`
  and the cluster expansion produces every letter the expansion would
  produce. A deny rule on letter `x` fires whether the shell expands to
  `-xa` or `-xb`. Long-name candidates also cover the prefix case
  (`--out{put,err}` → `out{put,err}` whose prefix `out` matches a rule
  listing `output`).
- **Positional side.** Rare and not in the bundled rules. If a rule listed a
  specific literal positional `a` to deny, `cmd {a,b}` would NOT match —
  the walker emits `{a,b}` as one token, not `a`. This is an
  under-approximation, but the only bundled positional patterns use globs
  (`*.pdf`, `*system*`), and a literal-positional deny is an unusual
  pattern. Accept as a known limitation.
- **Substitution inside braces** (`{$(rm),y}`). Same as concatenation — bail
  via `subtree_has_substitution`.

The empty-list / single-element edge cases (`{a}` is not valid brace
expansion — the shell leaves it literal; `{a,}` is two args `a` and empty)
don't matter for matching: the unexpanded text is still what the walker
sees, and any rule that would match the expanded form is matched character-
wise by the unexpanded form.

### Migration

Mechanical conversion of the current `lua/agentic/permissions.json` (396 glob
entries across `read_only`/`safe_write`/`deny`/`ask`) to the flat structured
form. Conversion principles applied uniformly:

- The option walker skips arg-taking globals before reading the first
  positional, so most `Bash(cmd *foo*)` and `Bash(cmd -X * foo *)` globs
  collapse to `positionals: ["foo"]` — no glob needed on the first
  positional. Mid-positional globs still apply where actual prefix
  matching is intended (rare: `positionals: ["list-*"]`).
- `positionals: ["config", "--get", "*"]` preserves "this option must
  appear in this position" intent without over-approving via
  `options: ["get"]`.
- Pipelines (`Bash(X | Y)`) are dropped: the walker already evaluates each
  pipe segment independently against all rules.
- `read_only` becomes per-entry `category: "read_only"` (the default;
  omitted for brevity); `safe_write` becomes explicit
  `category: "safe_write"`.
- `deny`/`ask` glob entries fold into the same command's gate, keeping each
  command's rules in one place.
- New flag-writer rules (`sort`, `tee`, expanded `curl`, `http`) added per
  the plan's § Migration "New rules" subsection.
- The `pwd*` typo (matches `pwdwhatever`) is dropped; `pwd` plus `pwd *`
  collapse to a single bare-command entry.

```jsonc
[
  // ── file/directory listing and metadata ────────────────────────────────
  { "cmd": "ls",        "allow": {} },
  { "cmd": "tree",      "allow": {} },
  { "cmd": "du",        "allow": {} },
  { "cmd": "df",        "allow": {} },
  { "cmd": "file",      "allow": {} },
  { "cmd": "stat",      "allow": {} },
  { "cmd": "wc",        "allow": {} },
  { "cmd": "column",    "allow": {} },
  { "cmd": "eza",       "allow": {} },
  { "cmd": "lsd",       "allow": {} },
  { "cmd": "bat",       "allow": {} },
  { "cmd": "fd",        "allow": {} },
  { "cmd": "mdfind",    "allow": {} },
  { "cmd": "locate",    "allow": {} },

  // xargs ls is the only xargs-prefixed entry; safest is to keep narrow.
  // merged from Bash(xargs ls *)
  { "cmd": "xargs", "allow": { "positionals": ["ls"] } },

  // ── path/name introspection ────────────────────────────────────────────
  { "cmd": "which",    "allow": {} },
  { "cmd": "whereis",  "allow": {} },
  { "cmd": "type",     "allow": {} },
  { "cmd": "realpath", "allow": {} },
  { "cmd": "readlink", "allow": {} },
  { "cmd": "dirname",  "allow": {} },
  { "cmd": "basename", "allow": {} },

  // merged from Bash(command -v *), Bash(command -V *)
  { "cmd": "command", "allow": { "options": ["v", "V"] } },

  // ── content readers ────────────────────────────────────────────────────
  { "cmd": "cat",      "allow": {} },
  { "cmd": "head",     "allow": {} },
  { "cmd": "tail",     "allow": {} },
  { "cmd": "less",     "allow": {} },
  { "cmd": "zless",    "allow": {} },
  { "cmd": "gzcat",    "allow": {} },
  { "cmd": "bzcat",    "allow": {} },
  { "cmd": "xzcat",    "allow": {} },
  { "cmd": "lz4cat",   "allow": {} },
  { "cmd": "zstdcat",  "allow": {} },

  // ── shell builtins / control ───────────────────────────────────────────
  { "cmd": "cd",       "allow": {} },
  { "cmd": "pwd",      "allow": {} },           // merged from Bash(pwd), Bash(pwd *); Bash(pwd*) typo dropped
  { "cmd": "echo",     "allow": {} },
  { "cmd": "printf",   "allow": {} },
  { "cmd": "seq",      "allow": {} },
  { "cmd": "true",     "allow": {} },
  { "cmd": ":",        "allow": {} },
  { "cmd": "false",    "allow": {} },
  { "cmd": "help",     "allow": {} },
  { "cmd": "sleep",    "allow": {}, "category": "safe_write" },

  // ── search ─────────────────────────────────────────────────────────────
  { "cmd": "grep",     "allow": {} },           // pipeline variant Bash(grep * | head *) dropped
  { "cmd": "rg",       "allow": {} },
  { "cmd": "ag",       "allow": {} },
  { "cmd": "ack",      "allow": {} },
  { "cmd": "pdfgrep",  "allow": {} },

  // merged from Bash(pdftotext *.pdf -)
  { "cmd": "pdftotext", "allow": { "positionals": ["*.pdf", "-"] } },

  // ── find / fd write-flag denies ────────────────────────────────────────
  // merged from Bash(find *) allow + Bash(find * -exec *), -delete*, -ok *, -okdir * denies
  // also folds Bash(find * -execdir *) from the ask section (deny takes precedence)
  { "cmd": "find",
    "allow": {},
    "deny":  { "options": ["exec", "execdir", "okdir", "delete", "ok"] } },

  // merged from Bash(fd *) allow + Bash(fd * -x *), -X *, --exec *, --exec-batch * denies
  { "cmd": "fd",
    "allow": {},
    "deny":  { "options": ["x", "X", "exec", "exec-batch"] } },

  // ── diff / cmp ─────────────────────────────────────────────────────────
  { "cmd": "diff", "allow": {} },
  { "cmd": "cmp",  "allow": {} },
  { "cmd": "comm", "allow": {} },

  // ── git: read-only subcommands ─────────────────────────────────────────
  // merged from Bash(git diff), Bash(git diff *), Bash(git *diff*)
  { "cmd": "git", "allow": { "positionals": ["diff"] } },
  // merged from Bash(git log), Bash(git log *), Bash(git *log*)
  { "cmd": "git", "allow": { "positionals": ["log"] } },
  // merged from Bash(git show), Bash(git show *), Bash(git show*)
  { "cmd": "git", "allow": { "positionals": ["show"] } },
  // merged from Bash(git status), Bash(git status *), Bash(git *status*)
  { "cmd": "git", "allow": { "positionals": ["status"] } },
  { "cmd": "git", "allow": { "positionals": ["blame"] } },
  // merged from Bash(git rev-parse *), Bash(git -C * rev-parse *)
  { "cmd": "git", "allow": { "positionals": ["rev-parse"] } },
  // merged from Bash(git branch), Bash(git branch *), Bash(git branch --list*)
  // (branch -d/-D/-m/-M/-c/-C/--delete/--move/--copy carved out below in ask)
  { "cmd": "git", "allow": { "positionals": ["branch"] },
    "ask":  { "positionals": ["branch"],
              "options":     ["d", "D", "m", "M", "c", "C",
                              "delete", "move", "copy"] } },
  // merged from Bash(git remote), Bash(git remote *), Bash(git remote -v),
  // Bash(git -C * remote), Bash(git -C * remote -v)
  { "cmd": "git", "allow": { "positionals": ["remote"] } },
  // merged from Bash(git tag), Bash(git tag *), Bash(git tag --list*)
  { "cmd": "git", "allow": { "positionals": ["tag"] } },
  // merged from Bash(git ls-files*), Bash(git *ls-files *)
  { "cmd": "git", "allow": { "positionals": ["ls-files"] } },
  // merged from Bash(git ls-tree*), Bash(git *ls-tree *)
  { "cmd": "git", "allow": { "positionals": ["ls-tree"] } },
  { "cmd": "git", "allow": { "positionals": ["cat-file"] } },

  // git config: read-only positional carve-outs (positional preserves intent)
  // merged from Bash(git config --get *)
  { "cmd": "git",
    "allow": { "positionals": ["config", "--get", "*"] } },
  // merged from Bash(git config --list *)
  { "cmd": "git",
    "allow": { "positionals": ["config", "--list", "*"] } },
  // merged from Bash(git config -f * --get *)
  { "cmd": "git",
    "allow": { "positionals": ["config", "-f", "*", "--get", "*"] } },
  // merged from Bash(git config -f * --list*)
  { "cmd": "git",
    "allow": { "positionals": ["config", "-f", "*", "--list", "*"] } },

  // git stash: list is read-only, push/drop/-m are ask
  // merged from Bash(git stash list *)
  { "cmd": "git",
    "allow": { "positionals": ["stash", "list"] } },
  // merged from Bash(git stash) and Bash(git stash push*), drop*, -m *
  { "cmd": "git", "ask": { "positionals": ["stash"] } },

  // git: write-side ask carve-outs
  // merged from Bash(git checkout *), Bash(git checkout -- *)
  { "cmd": "git", "ask": { "positionals": ["checkout"] } },
  // merged from Bash(git reset*)
  { "cmd": "git", "ask": { "positionals": ["reset"] } },
  // merged from Bash(git push*)
  { "cmd": "git", "ask": { "positionals": ["push"] } },
  // merged from Bash(git commit*), Bash(git * commit *)
  { "cmd": "git", "ask": { "positionals": ["commit"] } },

  // ── sort: deny output flags (cluster-proof, replaces unsound globs) ────
  { "cmd": "sort",
    "allow": {},
    "deny":  { "options": ["o", "output"] } },

  // ── uniq / cut / tr ────────────────────────────────────────────────────
  { "cmd": "uniq", "allow": {} },
  { "cmd": "cut",  "allow": {} },
  { "cmd": "tr",   "allow": {} },

  // tee is intentionally absent: it always writes. No entry → falls through
  // to a permission prompt. Users who want auto-approval add an entry to
  // Config.permissions.structured.

  // ── data-format tools ──────────────────────────────────────────────────
  { "cmd": "jq",      "allow": {} },
  // merged from Bash(yq *) allow + Bash(yq -i*), Bash(yq * -i*) asks
  { "cmd": "yq",
    "allow": {},
    "ask":   { "options": ["i"] } },
  { "cmd": "xq",      "allow": {} },
  { "cmd": "xmllint", "allow": {} },
  { "cmd": "xxd",     "allow": {} },
  { "cmd": "hexdump", "allow": {} },
  { "cmd": "od",      "allow": {} },
  { "cmd": "strings", "allow": {} },

  // ── hash / checksum ────────────────────────────────────────────────────
  { "cmd": "md5",       "allow": {} },
  { "cmd": "md5sum",    "allow": {} },
  { "cmd": "shasum",    "allow": {} },
  { "cmd": "sha256sum", "allow": {} },
  { "cmd": "cksum",     "allow": {} },

  // ── documentation / help ───────────────────────────────────────────────
  { "cmd": "man",     "allow": {} },
  { "cmd": "info",    "allow": {} },
  { "cmd": "apropos", "allow": {} },
  { "cmd": "whatis",  "allow": {} },
  { "cmd": "tldr",    "allow": {} },

  // ── system info ────────────────────────────────────────────────────────
  { "cmd": "uname",       "allow": {} },
  { "cmd": "hostname",    "allow": {} },
  // merged from Bash(date), Bash(date *) allow + Bash(date -s*), --set* denies
  { "cmd": "date",
    "allow": {},
    "deny":  { "options": ["s", "set"] } },
  { "cmd": "cal",         "allow": {} },
  { "cmd": "uptime",      "allow": {} },
  { "cmd": "id",          "allow": {} },
  { "cmd": "whoami",      "allow": {} },
  { "cmd": "groups",      "allow": {} },
  { "cmd": "who",         "allow": {} },
  { "cmd": "w",           "allow": {} },
  { "cmd": "nproc",       "allow": {} },
  { "cmd": "sw_vers",     "allow": {} },
  { "cmd": "lsblk",       "allow": {} },
  { "cmd": "lscpu",       "allow": {} },
  { "cmd": "lspci",       "allow": {} },
  { "cmd": "timedatectl", "allow": {} },
  { "cmd": "localectl",   "allow": {} },
  { "cmd": "loginctl",    "allow": {} },
  { "cmd": "free",        "allow": {} },
  { "cmd": "dmesg",       "allow": {} },
  { "cmd": "vulkaninfo",  "allow": {} },

  // ── processes ──────────────────────────────────────────────────────────
  { "cmd": "ps",     "allow": {} },
  { "cmd": "pgrep",  "allow": {} },
  { "cmd": "pidof",  "allow": {} },
  { "cmd": "pstree", "allow": {} },
  { "cmd": "lsof",   "allow": {} },

  // ── networking introspection ───────────────────────────────────────────
  { "cmd": "dig",        "allow": {} },
  { "cmd": "host",       "allow": {} },
  { "cmd": "nslookup",   "allow": {} },
  { "cmd": "ping",       "allow": {} },
  { "cmd": "traceroute", "allow": {} },
  { "cmd": "ss",         "allow": {} },
  { "cmd": "netstat",    "allow": {} },
  // pipeline variant Bash(mount | grep *) dropped
  { "cmd": "mount",      "allow": {} },

  // ── env ────────────────────────────────────────────────────────────────
  // NOTE: Bash(env *) auto-approves arbitrary commands via env wrapper —
  // tracked in notes/perm-wrapper-command-auto-approve.md (out of scope here).
  { "cmd": "env",      "allow": {} },
  { "cmd": "printenv", "allow": {} },

  // ── macOS-specific ─────────────────────────────────────────────────────
  // merged from Bash(defaults read), Bash(defaults read *)
  { "cmd": "defaults", "allow": { "positionals": ["read"] } },
  // merged from Bash(xattr), Bash(xattr -l *), Bash(xattr -h)
  { "cmd": "xattr",
    "allow": {},
    "ask":   { "options": ["w", "d", "c"] } },
  { "cmd": "log",      "allow": { "positionals": ["show"] } },

  // ── text-processing with write-flag carve-outs ─────────────────────────
  // merged from Bash(sed *) allow + Bash(sed -i*), Bash(sed * -i*) denies
  // residual: sed e/s///e (exec) and w/W/s///w (write) still leak — see § Remaining residuals
  { "cmd": "sed",
    "allow": {},
    "deny":  { "options": ["i"] } },

  // merged from Bash(awk *) allow + Bash(awk *system*) deny + Bash(awk * > *), Bash(awk *>*) asks
  // residual: awk system() inside the script body — covered by positionals "*system*"; redirects via the walker
  { "cmd": "awk",
    "allow": {},
    "deny":  { "positionals": ["*system*"] } },

  { "cmd": "bc",     "allow": {} },
  { "cmd": "getent", "allow": {} },

  // ── HDF5 / NetCDF ──────────────────────────────────────────────────────
  { "cmd": "h5dump", "allow": {} },
  { "cmd": "h5ls",   "allow": {} },
  { "cmd": "ncdump", "allow": {} },

  // ── journal / systemd ──────────────────────────────────────────────────
  { "cmd": "journalctl", "allow": {} },
  // merged from Bash(systemctl is-active *), is-enabled *, list-*, status *
  { "cmd": "systemctl", "allow": { "positionals": ["is-active"] } },
  { "cmd": "systemctl", "allow": { "positionals": ["is-enabled"] } },
  { "cmd": "systemctl", "allow": { "positionals": ["list-*"] } },
  { "cmd": "systemctl", "allow": { "positionals": ["status"] } },

  // ── sysctl / xdg ───────────────────────────────────────────────────────
  { "cmd": "sysctl",   "allow": {} },
  // merged from Bash(xdg-mime query *)
  { "cmd": "xdg-mime", "allow": { "positionals": ["query"] } },

  // ── lua / typst / latex ────────────────────────────────────────────────
  // merged from Bash(luac -l*)
  { "cmd": "luac",  "allow": { "options": ["l"] } },
  // merged from Bash(typst query *) read-only + Bash(typst *) safe_write
  { "cmd": "typst", "allow": { "positionals": ["query"] } },
  { "cmd": "typst", "allow": {}, "category": "safe_write" },
  // merged from Bash(latexmk *)
  { "cmd": "latexmk", "allow": {}, "category": "safe_write" },
  // merged from Bash(tlmgr *)
  { "cmd": "tlmgr",   "allow": {}, "category": "safe_write" },

  // ── java introspection ─────────────────────────────────────────────────
  { "cmd": "javap", "allow": {} },

  // ── universal --help/--version ─────────────────────────────────────────
  // merged from Bash(* --help), Bash(* --version)
  { "cmd": "*", "allow": { "options": ["help", "version"] } },

  // ── universal first-positional "list*" (informational subcommands) ─────
  // merged from Bash(* list*) (and pipeline variant Bash(* list *| grep *) dropped)
  { "cmd": "*", "allow": { "positionals": ["list*"] } },

  // ── package managers (read-only info subcommands) ──────────────────────
  // merged from Bash(brew info *), Bash(brew list *), Bash(brew search *)
  { "cmd": "brew", "allow": { "positionals": ["info"] } },
  { "cmd": "brew", "allow": { "positionals": ["list"] } },
  { "cmd": "brew", "allow": { "positionals": ["search"] } },

  // merged from Bash(cargo doc *), Bash(cargo metadata *), Bash(cargo tree *)
  { "cmd": "cargo", "allow": { "positionals": ["doc"] } },
  { "cmd": "cargo", "allow": { "positionals": ["metadata"] } },
  { "cmd": "cargo", "allow": { "positionals": ["tree"] } },

  // merged from Bash(conda info *), Bash(conda list *), Bash(conda search *), Bash(conda env *)
  { "cmd": "conda", "allow": { "positionals": ["info"] } },
  { "cmd": "conda", "allow": { "positionals": ["list"] } },
  { "cmd": "conda", "allow": { "positionals": ["search"] } },
  { "cmd": "conda", "allow": { "positionals": ["env"] } },

  { "cmd": "flatpak", "allow": { "positionals": ["info"] } },
  { "cmd": "flatpak", "allow": { "positionals": ["list"] } },

  { "cmd": "npm", "allow": { "positionals": ["info"] } },
  { "cmd": "npm", "allow": { "positionals": ["list"] } },
  { "cmd": "npm", "allow": { "positionals": ["view"] } },

  // merged from Bash(pacman -Q*), Bash(pacman -Si *), Bash(pacman -Ss *)
  { "cmd": "pacman", "allow": { "options": ["Q", "Si", "Ss"] } },

  { "cmd": "pip", "allow": { "positionals": ["list"] } },
  { "cmd": "pip", "allow": { "positionals": ["show"] } },

  { "cmd": "pnpm", "allow": { "positionals": ["info"] } },

  // merged from Bash(uv pip list *), Bash(uv pip search *), Bash(uv pip show *)
  { "cmd": "uv", "allow": { "positionals": ["pip", "list"] } },
  { "cmd": "uv", "allow": { "positionals": ["pip", "search"] } },
  { "cmd": "uv", "allow": { "positionals": ["pip", "show"] } },
  // merged from Bash(uv lock)
  { "cmd": "uv", "allow": { "positionals": ["lock"] }, "category": "safe_write" },

  // merged from Bash(luarocks search *)
  { "cmd": "luarocks", "allow": { "positionals": ["search"] },
    "category": "safe_write" },

  // ── gh (GitHub CLI) ────────────────────────────────────────────────────
  // merged from Bash(gh alias list *), and similar
  { "cmd": "gh", "allow": { "positionals": ["alias", "list"] } },
  // merged from Bash(gh api *) allow + Bash(gh api *-X*), --method*, -f*, -F*, --input* asks
  { "cmd": "gh",
    "allow": { "positionals": ["api"] },
    "ask":   { "positionals": ["api"],
               "options":     ["X", "method", "f", "F", "input"] } },
  { "cmd": "gh", "allow": { "positionals": ["auth", "status"] } },
  { "cmd": "gh", "allow": { "positionals": ["cache", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["config", "get"] } },
  { "cmd": "gh", "allow": { "positionals": ["config", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["extension", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["gist", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["gist", "view"] } },
  { "cmd": "gh", "allow": { "positionals": ["issue", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["issue", "status"] } },
  { "cmd": "gh", "allow": { "positionals": ["issue", "view"] } },
  // merged from Bash(gh issue create *)
  { "cmd": "gh", "ask":   { "positionals": ["issue", "create"] } },
  { "cmd": "gh", "allow": { "positionals": ["label", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["org", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["pr", "checks"] } },
  { "cmd": "gh", "allow": { "positionals": ["pr", "diff"] } },
  { "cmd": "gh", "allow": { "positionals": ["pr", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["pr", "status"] } },
  { "cmd": "gh", "allow": { "positionals": ["pr", "view"] } },
  { "cmd": "gh", "allow": { "positionals": ["project", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["project", "view"] } },
  { "cmd": "gh", "allow": { "positionals": ["release", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["release", "view"] } },
  { "cmd": "gh", "allow": { "positionals": ["repo", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["repo", "view"] } },
  { "cmd": "gh", "allow": { "positionals": ["ruleset"] } },
  { "cmd": "gh", "allow": { "positionals": ["run", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["run", "view"] } },
  { "cmd": "gh", "allow": { "positionals": ["search"] } },
  { "cmd": "gh", "allow": { "positionals": ["status"] } },
  { "cmd": "gh", "allow": { "positionals": ["workflow", "list"] } },
  { "cmd": "gh", "allow": { "positionals": ["workflow", "view"] } },

  // ── aws ────────────────────────────────────────────────────────────────
  // merged from Bash(aws s3 ls *)
  { "cmd": "aws", "allow": { "positionals": ["s3", "ls"] } },
  // merged from Bash(aws * get-*), describe-*, list-*, head-*
  // The first-positional pattern matches the service name (which varies),
  // while the second positional matches the read-only verb prefix.
  // `aws ec2 describe-instances` → positionals=["ec2", "describe-instances"]
  // matches positionals=["*", "describe-*"].
  { "cmd": "aws", "allow": { "positionals": ["*", "get-*"] } },
  { "cmd": "aws", "allow": { "positionals": ["*", "describe-*"] } },
  { "cmd": "aws", "allow": { "positionals": ["*", "list-*"] } },
  { "cmd": "aws", "allow": { "positionals": ["*", "head-*"] } },

  // ── kitty (terminal) ───────────────────────────────────────────────────
  // merged from Bash(kitty @ ls*), Bash(kitty @ ls | head *), Bash(kitty @ get-text*)
  // pipeline variant dropped. `@` is a literal positional (the kitty
  // remote-control sigil), not a subcommand sentinel.
  { "cmd": "kitty", "allow": { "positionals": ["@", "ls"] } },
  { "cmd": "kitty", "allow": { "positionals": ["@", "get-text"] } },

  // ── hyprctl (Hyprland) ─────────────────────────────────────────────────
  // merged from numerous Bash(hyprctl SUBCOMMAND*) entries
  { "cmd": "hyprctl", "allow": { "positionals": ["activewindow"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["activeworkspace"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["animations"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["binds"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["clients"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["configerrors"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["cursorpos"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["decorations"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["devices"] } },
  // merged from Bash(hyprctl get*), Bash(hyprctl getoption *), Bash(hyprctl getprop *)
  { "cmd": "hyprctl", "allow": { "positionals": ["get*"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["globalshortcuts"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["instances"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["layers"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["layouts"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["monitors"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["rollinglog"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["splash"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["systeminfo"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["version"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["workspacerules"] } },
  { "cmd": "hyprctl", "allow": { "positionals": ["workspaces"] } },

  // ── safe-write data tools ──────────────────────────────────────────────
  // merged from Bash(mlr *) safe_write + Bash(mlr -I*), Bash(mlr * -I*) denies
  // pipeline variants Bash(mlr *| head *), Bash(printf * | mlr *) dropped
  { "cmd": "mlr",
    "allow": {},
    "deny":  { "options": ["I"] },
    "category": "safe_write" },

  // merged from Bash(qalc *)
  { "cmd": "qalc",  "allow": {}, "category": "safe_write" },
  // merged from Bash(paste *)
  { "cmd": "paste", "allow": {}, "category": "safe_write" },
  // merged from Bash(tac *)
  { "cmd": "tac",   "allow": {}, "category": "safe_write" },

  // ── curl: deny output/upload flags (expanded per § Migration new rules) ─
  // merged from Bash(curl *) safe_write + Bash(curl * -o *), --output *, -O*, --remote-name* denies
  // New denies added: -K/--config, -T/--upload-file, -D/--dump-header, --output-dir, --trace-ascii
  { "cmd": "curl",
    "allow": {},
    "deny":  { "options": ["o", "O", "output", "remote-name",
                           "K", "config",
                           "T", "upload-file",
                           "D", "dump-header",
                           "output-dir", "trace-ascii"] },
    "category": "safe_write" },

  // ── http (httpie): new flag-writer deny rules ──────────────────────────
  // merged from Bash(http *) safe_write
  // New denies: -d/--download, -o/--output
  { "cmd": "http",
    "allow": {},
    "deny":  { "options": ["d", "download", "o", "output"] },
    "category": "safe_write" },

  // ── build / test / lint ────────────────────────────────────────────────
  { "cmd": "just", "allow": { "positionals": ["lint"] },
    "category": "safe_write" },
  { "cmd": "just", "allow": { "positionals": ["type"] },
    "category": "safe_write" },

  { "cmd": "make", "allow": { "positionals": ["test"] },
    "category": "safe_write" },
  { "cmd": "make", "allow": { "positionals": ["validate"] },
    "category": "safe_write" },

  { "cmd": "bun",  "allow": { "positionals": ["test"] },
    "category": "safe_write" },

  // merged from Bash(ruff *) safe_write + Bash(ruff * --fix*), Bash(ruff * -fix*) denies
  // -fix*: literal `-fix` is malformed (single dash long form), kept as a defensive deny
  { "cmd": "ruff",
    "allow": {},
    "deny":  { "options": ["fix"] },
    "category": "safe_write" },

  { "cmd": "selene", "allow": {}, "category": "safe_write" },

  // merged from Bash(stylua *) safe_write + Bash(stylua * --replace*) deny
  { "cmd": "stylua",
    "allow": {},
    "deny":  { "options": ["replace"] },
    "category": "safe_write" },

  // merged from Bash(tree-sitter *)
  { "cmd": "tree-sitter", "allow": {}, "category": "safe_write" },
  // merged from Bash(npx tree-sitter *)
  { "cmd": "npx", "allow": { "positionals": ["tree-sitter"] },
    "category": "safe_write" },

  // ── claude (CLI) ───────────────────────────────────────────────────────
  // merged from Bash(claude config list *)
  { "cmd": "claude", "allow": { "positionals": ["config", "list"] },
    "category": "safe_write" },
  // merged from Bash(claude mcp list *)
  { "cmd": "claude", "allow": { "positionals": ["mcp", "list"] },
    "category": "safe_write" },

  // ── flyte ──────────────────────────────────────────────────────────────
  { "cmd": "flyte",    "allow": { "positionals": ["get"] },
    "category": "safe_write" },
  { "cmd": "flytectl", "allow": { "positionals": ["get"] },
    "category": "safe_write" },

  // ── zsh syntax-check / python -m unittest ──────────────────────────────
  // merged from Bash(zsh -n *)
  { "cmd": "zsh", "allow": { "options": ["n"] }, "category": "safe_write" },
  // merged from Bash(python3 -m unittest*)
  { "cmd": "python3",
    "allow": { "options": ["m"], "positionals": ["unittest*"] },
    "category": "safe_write" },

  // ── headless graphics ──────────────────────────────────────────────────
  // merged from Bash(blender --background *)
  { "cmd": "blender", "allow": { "options": ["background"] },
    "category": "safe_write" },
  // merged from Bash(pymol *)
  { "cmd": "pymol",   "allow": {}, "category": "safe_write" },

  // ── ask gates: destructive but recoverable ─────────────────────────────
  // merged from Bash(rm *)
  { "cmd": "rm", "ask": {} }
]
```

#### Migration notes

**Collapses** (groups of glob entries → single structured entry):

1. `Bash(git diff)`, `Bash(git diff *)`, `Bash(git *diff*)` → one entry with
   `subcommand: "diff"`. Same shape for `log`, `show`, `status`, `remote`,
   `tag`, `ls-files`, `ls-tree`, `rev-parse` — eleven git subcommand globs
   collapse to a one-per-subcommand entry.
2. `Bash(git -C * rev-parse *)` and `Bash(git -C * remote)`/`Bash(git -C *
   remote -v)` fold into the unprefixed entry — subcommand resolution skips
   `-C <path>` structurally.
3. `Bash(pwd)`, `Bash(pwd *)`, `Bash(pwd*)` → one entry. The `pwd*` typo
   (matches `pwdwhatever`) is dropped.
4. `Bash(branch --list*)` plus `Bash(branch)`/`Bash(branch *)` plus
   `Bash(branch -d *)`/`-D`/`-m`/`-M`/`-c`/`-C`/`--delete`/`--move`/`--copy`
   collapse to one allow + one ask gate on subcommand `branch`.
5. `Bash(find *)` allow + four `find` deny globs (`-exec`, `-delete*`,
   `-ok *`, `-okdir *`) plus the ask-side `-execdir *` collapse into a
   single `find` entry with `allow: {}` + `deny: {options: [...]}`.
6. `Bash(fd *)` + four `fd` deny globs (`-x *`, `-X *`, `--exec *`,
   `--exec-batch *`) collapse to one entry.
7. `Bash(curl *)` + four existing curl denies + the five **new** denies
   (`-K`, `-T`, `-D`, `--output-dir`, `--trace-ascii`) collapse into one
   entry with a single `deny.options` array.
8. `Bash(yq *)` + `Bash(yq -i*)` + `Bash(yq * -i*)` → one entry,
   `allow: {}` + `ask: {options: ["i"]}`.
9. `Bash(date)`, `Bash(date *)` + `Bash(date -s*)` + `Bash(date --set*)`
   → one entry with `deny: {options: ["s", "set"]}`.
10. `Bash(* --help)` + `Bash(* --version)` → single `cmd: "*"` entry with
    both option names.

**Drops** (pipeline globs the walker handles structurally — every entry
listed below is removed):

- `Bash(grep * | head *)`
- `Bash(mount | grep *)`
- `Bash(* list *| grep *)`
- `Bash(mlr *| head *)`
- `Bash(printf * | mlr *)`
- `Bash(kitty @ ls | head *)`

**New flag-writer rules** (added at migration time, not present in the
current JSON):

- `sort` — `deny: {options: ["o", "output"]}`. Catches `-o`, `-uo`,
  `-oFILE`, `--output=x`, `--out=x`. No current entry.
- `tee` — **dropped entirely**. The current JSON had `Bash(tee *)` under
  `safe_write`. `tee` always writes, so it should not auto-approve.
  No-entry → falls through to a permission prompt, which is the correct
  default. Users who genuinely want auto-approval (e.g. piping to a
  per-project log) add their own entry to `Config.permissions.structured`.
  This is a deliberate behaviour change vs. the previous auto-approval at
  `auto_approve = "allow"`; flag in the PR description.
- `curl` — added `-K`/`--config`, `-T`/`--upload-file`,
  `-D`/`--dump-header`, `--output-dir`, `--trace-ascii` (in addition to
  the already-converted `-o`/`-O`/`--output`/`--remote-name`).
- `http` (httpie) — new entry with `deny: {options: ["d", "download",
  "o", "output"]}`. Current JSON had only `Bash(http *)` allow.

**Audit findings**:

- `Bash(awk *system*)` deny converts to `{positionals: ["*system*"]}` on
  `awk`. The plan (§259) calls this out as the parser-independent
  backstop — sound regardless of whether the zsh injection query
  populates awk's subtree. Two ask entries `Bash(awk * > *)` and
  `Bash(awk *>*)` are **not** translated as structured entries because
  redirects are classified structurally by the walker (`file_redirect`
  to a non-`/dev/null` target bails). They become redundant under
  Phase 1a + 1b — explicitly listed as dropped because the walker fires
  first.
- `Bash(sed *)` allow + `Bash(sed -i*)` / `Bash(sed * -i*)` deny convert
  cleanly to `sed` with `deny: {options: ["i"]}`. § Remaining residuals
  documents that `sed e/s///e/w/W` still escape this layer — accepted
  limitation, no rule attempts to catch it (a `*e*` positional glob
  denies most real sed use).
- `Bash(ruff * -fix*)` is a malformed single-dash long form (real ruff
  uses `--fix`). Folded into the `fix` long-name deny by candidate
  prefix-match — defensible defensive coverage.
- `Bash(stylua * --replace*)` — `--replace` is the actual long flag;
  folded into `deny.options: ["replace"]`.
- `Bash(branch *--delete *)` etc.: the leading `*` is consuming
  arg-taking-global-like noise (`git branch -r --delete foo`). Structured
  subcommand resolution drops the leading `*`; the option is now in
  `ask.options`.
- `Bash(env *)` survives unchanged as a known wrapper-command escape —
  explicitly flagged in `notes/perm-wrapper-command-auto-approve.md`,
  out of scope for Phase 1b. Same out-of-scope deferral applies to other
  transparent wrappers (`time`, `xargs`, `nohup`, `sudo`, `nice`,
  `stdbuf`): Phase 1b doesn't add wrapper-transparency, but it also
  doesn't make these worse — `time grep foo` does not auto-approve today
  and still won't after migration. The wrapper-transparency plan is
  responsible for letting these prefixes pass through to the inner
  command's rules.
- `Bash(* list*)` becomes `{cmd: "*", allow: {positionals: ["list*"]}}`.
  The trailing `*` is a real glob on the first positional (covers
  `list-pods`, `list-buckets`, etc.) — preserved.
- `Bash(pacman -Q*)`, `-Si *`, `-Ss *`: pacman's short-form action flags
  fold into `options: ["Q", "Si", "Ss"]`. Letter-set expansion makes
  `-Q` and the long-name `Si`/`Ss` both candidates.
- Duplicate-shape pairs `Bash(systemctl list-*)` plus `Bash(* list*)`:
  the `*` entry already covers it but the `systemctl` entry is kept
  for clarity (cheap, non-overlapping with denies). Not strictly
  redundant — survives.
- `Bash(awk * > *)`, `Bash(awk *>*)` — dropped; walker `file_redirect`
  classification handles redirects structurally.

**Entry count**: 396 glob entries → 269 structured entries (the
collapse is driven by git/hyprctl/gh subcommand folding and deny-into-
same-command merges; pipeline drops contribute a small share; the
`tee` drop removes one more). Every entry in the current
`permissions.json` is either present in the new file (possibly merged),
explicitly listed as dropped (`tee`, pipelines, `pwd*` typo, `awk
*>*` ask entries), or replaced by a structurally-equivalent new entry.
The chunk-7 implementation MUST run `jq 'length'` to confirm the count.

### Injected-sublanguage descent (opportunistic only)

The config's `queries/zsh/injections.scm` injects awk/jq/sql/python/etc. into
command-argument strings, and `get_string_parser(cmd, "zsh")` + `parse(true)`
resolves those subtrees when that query is on the runtimepath. The injection
is not intrinsic to the zsh parser — in a clean env (`-u NONE`, only
`~/.local/share/nvim/site` on rtp) `awk 'BEGIN{system(...)}'` resolves as zsh
only. agentic.nvim is a submodule of the config that owns the injection query,
so the subtree is present in situ, but other consumers of the plugin (or a
config change) can remove it.

So injection descent is **best-effort enrichment** — a future Phase 1b
refinement that walks awk's `system()`/`print >`/pipe-to-command nodes,
sqlite3's SELECT-vs-write classification, and so on. It must never be the only
guard for a sub-language hole. The parser-independent backstops are the
`{cmd: "awk", deny: {positionals: ["*system*"]}}` entry (replacing the shipped
`Bash(awk *system*)` glob deny) and the `awk` ask entries for redirect
patterns — keep both regardless of injection descent.

### Remaining residuals (genuinely uncatchable, document)

- `sed` `e`/`s///e` (exec) and `w`/`W`/`s///w` (write) — no sed
  parser/injection, so the script body is opaque. Same tier as `awk -f
  scriptfile`. Keep `sed` in the allow list with a deny on `-i`, and document
  the residual: a glob carve-out inside the positional field is unsound (GNU
  sed needs no space after `e`, accepts a bare `e`, accepts an address
  prefix, `s///e` allows any delimiter and any flag order). Precise patterns
  leak. The only bypass-free positional glob (`"*e*"`) denies most real sed
  use.
- Dynamic expansion (`sort $FLAG out` where `$FLAG=-o`) — pre-existing limit,
  already tolerated for any `$var`/glob/`~`.

### Phase 1b tests

- `sort -uo out` (short cluster), `sort --out=x` (GNU abbreviation),
  `sort -oFILE` (glued arg) → all deny via
  `{cmd: "sort", deny: {options: ["o", "output"]}}`.
- `git -C diff push` → option walker consumes `-C diff`, positionals
  resolve to `["push"]`, not `["diff", "push"]` → prompt (allow gate
  `positionals: ["diff"]` does not match).
- `git -C path config --get foo` → option walker consumes `-C path`,
  positionals resolve to `["config", "--get", "foo"]` which match
  `["config", "--get", "*"]` → allow.
- `pdftotext *.pdf -` → approve via positional-glob allow.
- `tee out` → prompt (no entry — `tee` is intentionally absent from
  `permissions.json` so it falls through; users opt-in via
  `Config.permissions.structured`).
- `curl -K config.txt` → deny (config-file write/exfil flag).
- `ls --help` → approve via `{cmd: "*", allow: {options: ["help"]}}`.
- `mlr -I foo` with `auto_approve = "read-only"` → deny gate fires
  unconditionally; even at `auto_approve = "allow"` the deny wins.
- `mlr foo` with `auto_approve = "read-only"` → no approval (entry's allow
  gate is filtered out by category); falls through to glob layer or prompt.
- `mlr foo` with `auto_approve = "allow"` → approve.

### Work breakdown

Phase 1b is large enough to split across multiple subagents. Two passes:
**plan-fleshing** (this file grows) then **implementation** (code lands).
Tests are written before the matcher code — the test file is committed in a
failing state, and the diff that introduces the matcher module is the one
that turns the tests green.

#### Plan-fleshing pass (sequential then parallel)

Each chunk appends a self-contained subsection to this file. Each subagent
gets briefed with the specific section it owns.

1. **Test corpus (sequential, first).** Produce
   `lua/agentic/utils/permission_structured.test.lua` as a real Lua file with
   `describe`/`it` blocks and `assert.equal(...)` lines targeting
   not-yet-existing functions in `permission_structured.lua`. Anchor it to
   `require`-skip until the module exists (e.g. wrap with `pcall(require, ...)`
   + `pending(...)` so `make test` stays green pre-implementation). Cases
   cover:
   - cluster expansion (`-uo`, `--output=x`, `-oFILE`, quoted forms,
     edge cases like `--`, `-`, `--=`, `-=x`)
   - option matching (letter exact, long-name prefix-by-candidate, both
     directions of the prefix relationship)
   - arg resolution (option walker skips arg-taking globals,
     `git -C path diff`, empty positionals when only options present)
   - positional matching (in-order, trailing-allowance,
     literal-vs-glob per element)
   - gate evaluation (`allow`/`ask`/`deny` composition within an entry)
   - entry composition (multiple entries on same cmd, deny > ask > allow
     across entries)
   - category filtering (`read_only` vs `safe_write` against the three
     `auto_approve` values)
   - the full end-to-end cases already enumerated in § Phase 1b tests above

2. **Matcher API spec (parallel, after #1).** Append a "§ Matcher API"
   subsection: exact function signatures
   (`extract_option_candidates(token: string) -> string[]`,
   `match_options(candidates, rule_options) -> bool`,
   `resolve_args(args, cmd_name) -> { positionals, option_tokens }`,
   `decide_leaf(entries, parsed) -> "allow" | "ask" | "deny" | nil`),
   precise algorithm for cluster expansion (quote-strip → `=value` strip →
   letter-set + long-name branch), the option-matching rule (letters exact,
   long-name candidate-is-prefix-of-rule-option), and the per-command
   arg-taking-globals table (at minimum `git`'s `-C/-c/--git-dir/--work-tree`;
   audit the current `permissions.json` for any other commands that need
   entries).

3. **Walker token-extraction spec (parallel, after #1).** Append a
   "§ Walker integration" subsection: which `command` child node types
   become tokens for the structured matcher, how `string`/`raw_string` get
   quote-stripped, how `concatenation` is handled (bail vs join), how
   `variable_assignment` env-prefixes are excluded, and how the walker
   emits both leaf-text (for the glob layer) and the token list (for the
   structured layer) in a single pass. Document the composition site in
   `walk_command` where the four-way combine happens.

4. **Migration table (parallel, after #1).** Append a "§ Full migration"
   subsection. Convert every entry in the current `lua/agentic/permissions.json`
   (~260 entries across `read_only`/`safe_write`/`deny`/`ask`) to its
   structured form, organised by command. Note collapses (multiple glob
   entries → one structured entry), drops (pipelines), and the new
   flag-writer rules (`sort`, `tee`, expanded `curl`, `http`). Output is a
   JSONC block ready to drop into `permissions.json`.

#### Implementation pass (sequential)

5. **Module + tests turning green.** Write `permission_structured.lua` to
   the spec from #2. Flip the test file's `pending`s to live assertions.
   No walker or `permissions.json` changes yet.

6. **Walker integration.** Update `permission_rules.lua` per #3. Add the
   four-way composition. Existing Phase 1a tests must stay green.

7. **JSON migration.** Replace `lua/agentic/permissions.json` per #4. Add
   integration tests (cases in § Phase 1b tests) that exercise both layers
   together.

8. **Docs.** Update `CLAUDE.md` § "Compound Bash commands",
   `lua/agentic/acp/AGENTS.md` § "Compound Bash commands", and the README
   permissions section per § "Docs to update on completion".

Chunks 2/3/4 read the test file (#1) for grounding but do not depend on
each other. They can be three concurrent subagents. Chunks 5–8 are
sequential — each consumes the previous chunk's output.

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
