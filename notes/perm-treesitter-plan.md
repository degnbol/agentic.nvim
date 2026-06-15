# Treesitter-based compound-command auto-approval — Phase 1b

## Status

Phase 0 (permissions.json defence-in-depth) and Phase 1a (zsh treesitter walker
swap) have shipped on `main`:

- Walker at `lua/agentic/utils/permission_rules.lua` (commit `19710f8`)
- `awk *system*` deny (commit `4c81e35`), `find * -okdir *` deny (`0092dbc`)
- Five replaced helpers deleted (`split_command`, `mask_quoted_operators`,
  `has_unsafe_redirect`, `strip_devnull_redirects`, `is_inert_segment`)
- `glob_to_lua_pattern`: `*` → `.*`
- `sed e`/`s///e` residual accepted as a documented limitation (see § Remaining
  residuals)

**Phase 1b** (this document) is the in-flight work on branch `phase-1b`,
currently at commit `WIP: Phase 1b structured matcher (pre-schema-refactor)`.
A grilling session settled the design — cmd-keyed schema with
`read_only`/`safe_write`/`ask`/`deny` kinds, override via
`vim.tbl_deep_extend`, missing flag variants audited, cluster-bypass
closure rules added. The implementation chunks in § Work breakdown
refactor the WIP commit to that design.

**Phase 2** (assignment-position substitution + loops) lives on branch
`phase-2-substitution-loops` — see
[perm-substitution-loops-plan.md](perm-substitution-loops-plan.md). It
depends on Phase 1b and will be rebased onto `main` after Phase 1b lands.

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

`permissions.json` is a **cmd-keyed object**. Each top-level key is the
command name; each value is a record with up to four gate-kind arrays:
`read_only`, `safe_write`, `ask`, `deny`. Each gate in those arrays carries
an `options` constraint and/or a `positionals` constraint.

```jsonc
{
  "find": {
    "read_only": [{}],
    "deny":      [{ "options": ["exec", "execdir", "okdir", "delete", "ok"] }]
  },

  "sed": {
    "read_only": [{}],
    "deny":      [{ "options": ["i", "in-place"] }]
  },

  "yq": {
    "read_only": [{}],
    "ask":       [{ "options": ["i", "in-place"] }]
  },

  "gh": {
    "read_only": [{ "positionals": ["api"] }],
    "ask":       [{ "positionals": ["api"],
                    "options":     ["X", "method", "f", "F", "input"] }]
  },

  "pdftotext": {
    "read_only": [{ "positionals": ["*.pdf", "-"] }]
  },

  "git": {
    "read_only": [
      { "positionals": ["diff"] },
      { "positionals": ["log"] },
      { "positionals": ["config", "--get", "*"] }
    ],
    "ask": [
      { "positionals": ["push"] }
    ]
  },

  "mlr": {
    "safe_write": [{}],
    "deny":       [{ "options": ["I", "in-place"] }]
  },

  "typst": {
    "read_only":  [{ "positionals": ["query"] }],
    "safe_write": [{}]
  },

  "pacman": {
    "read_only": [{ "options": ["Q", "Si", "Ss"] }],
    "ask":       [{ "options": ["R", "U", "D", "F", "T"] }]
  },

  "rm": { "ask": [{}] },

  "*": {
    "read_only": [
      { "options": ["help", "version"] },
      { "positionals": ["list*"] }
    ]
  }
}
```

Top-level layout:

- **Key** — literal command name (after `strip_command_path`), or `"*"` for
  cross-command rules. `"*"` is matched as a literal key, not as a glob —
  no other key shape acts as a wildcard.
- **Value** — object with four optional fields, each an array of gates:
  - **`read_only`** — auto-approves at `auto_approve = "read-only"` or
    `"allow"`.
  - **`safe_write`** — auto-approves at `auto_approve = "allow"` only
    (mutates-but-safe — `mkdir`, `touch`, `git add`).
  - **`ask`** — unconditionally prompts. Beats every approval kind.
  - **`deny`** — unconditionally vetoes. Beats `ask`.

The kind name encodes the policy. There is no separate `category` field.

Gate shape (each element of those arrays):

```jsonc
{ "options":     ["help"],              // optional; literal flag names
  "positionals": ["config", "--get"] }  // optional; literal or glob
```

An empty gate `{}` matches the bare command (no further constraints). Any
field present must match.

Gate-field semantics:

- **`options`** — list of flag identifiers (short letters or long names). A
  candidate set is built from every literal arg token via the cluster
  expansion below; the gate matches if any candidate is in the list.
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
| top-level key | only exact `"*"` |
| `positionals[i]` | yes |
| `options[i]` | no — literal flag identifiers |

Glob syntax is the same `*` as Claude's `Bash(...)` patterns (also used by the
existing glob layer).

#### User overrides via `Config.permissions.structured`

`Config.permissions.structured` is a cmd-keyed table with the same shape.
At load time the matcher computes
`vim.tbl_deep_extend("force", bundled, user)` — user keys win at the
cmd granularity. To override a specific gate kind without restating the
others, the user supplies only that field. To remove a bundled cmd entry
entirely, set the cmd key to `vim.NIL`; the matcher treats `vim.NIL` as
"no entry."

Examples:

```lua
require("agentic").setup({
    permissions = {
        structured = {
            -- Silence pacman's ask on -R/-U/etc. — auto-approve at own risk.
            pacman = { ask = {} },

            -- Add a tee allow.
            tee = { safe_write = { {} } },

            -- Disable the bundled rm ask entirely.
            rm = vim.NIL,

            -- Add new positional to git's allow list. NOTE: this REPLACES
            -- the bundled git.read_only array — the user must restate any
            -- bundled gates they want to keep.
            git = {
                read_only = {
                    { positionals = { "diff" } },
                    { positionals = { "log" } },
                    { positionals = { "config", "--get", "*" } },
                    { positionals = { "amend-summary" } }  -- new
                }
            }
        },
    },
})
```

The "restate to extend" friction is the cost of single-knob simplicity. A
second `Config.permissions.structured_add` (flat union) is reserved for
the future if real users hit the extension pattern often enough.

### Entry composition

Per leaf, look up two entries at most:

- `cmd_entry = entries[parsed.cmd_name]`
- `wild_entry = entries["*"]`

Either may be absent. Their kind-arrays compose:

- **deny** if any gate in `cmd_entry.deny ++ wild_entry.deny` fires;
- else **ask** if any gate in `cmd_entry.ask ++ wild_entry.ask` fires;
- else **allow** if any gate in the eligible-kinds union fires:
  - `auto_approve == "allow"` → `read_only ++ safe_write`
  - `auto_approve == "read-only"` → `read_only` only
  - `auto_approve == nil` → empty (no allow gate can fire)
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

`StructuredCmdEntry` mirrors one value of the cmd-keyed JSON schema in
§ Structured schema. The entry table itself maps `cmd_name` → `StructuredCmdEntry`.
Optional kind-array fields are absent (not `vim.NIL`) when unspecified —
`vim.json.decode` of `permissions.json` already produces this shape.

```lua
--- @alias agentic.PermAutoApprove "allow" | "read-only" | nil
--- @alias agentic.PermDecision "allow" | "ask" | "deny" | nil
--- @alias agentic.PermKind "read_only" | "safe_write" | "ask" | "deny"

--- @class agentic.PermGate
--- @field options?     string[] -- literal flag identifiers, no globs
--- @field positionals? string[] -- per element literal or glob

--- @class agentic.StructuredCmdEntry
--- @field read_only?  agentic.PermGate[]
--- @field safe_write? agentic.PermGate[]
--- @field ask?        agentic.PermGate[]
--- @field deny?       agentic.PermGate[]

--- Cmd-keyed table. `vim.NIL`-valued keys are treated as "no entry" so the
--- user can disable a bundled cmd via `Config.permissions.structured`.
--- @alias agentic.StructuredEntries table<string, agentic.StructuredCmdEntry|nil>

--- @class agentic.ParsedLeaf
--- @field cmd_name string    after strip_command_path / wrapper strip
--- @field args     string[]  quote-stripped, env-prefix/redirect-excluded

--- @class agentic.ResolvedArgs
--- @field positionals   string[]    non-option tokens, in source order
--- @field option_tokens string[]    leading option tokens + consumed values
```

The walker is the sole producer of `ParsedLeaf`. The matcher trusts its
input.

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

--- Look up entries[cmd_name] and entries["*"] (either may be nil/vim.NIL),
--- then resolve deny > ask > allow across both. Allow gates are restricted
--- to the kind set selected by `auto_approve`.
--- @param entries      agentic.StructuredEntries
--- @param parsed       agentic.ParsedLeaf
--- @param auto_approve agentic.PermAutoApprove
--- @return agentic.PermDecision
function M.decide_leaf(entries, parsed, auto_approve) end
```

Internal helpers (not exported, named so reviewers can grep):
`gate_matches`, `positionals_match`, `collect_option_candidates`,
`match_one`, `eligible_allow_kinds`. None are called by the test file;
the public four cover every assertion in
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

#### Entry composition

`decide_leaf(entries, parsed, auto_approve)`:

```text
1. Resolve once:
       resolved  = resolve_args(parsed.args, parsed.cmd_name)
       opt_cands = collect candidates from
                       resolved.option_tokens
                       ++ { t in resolved.positionals : t:sub(1,1) == "-" }

2. Look up the two relevant cmd entries:
       cmd_entry  = entries[parsed.cmd_name]
       wild_entry = entries["*"]
       relevant   = filter non-nil/non-vim.NIL from [cmd_entry, wild_entry]

3. For deny then ask (unconditional kinds):
       for entry in relevant:
           for gate in entry.deny or {}:
               if gate_matches(gate, resolved, opt_cands) → return "deny"
       for entry in relevant:
           for gate in entry.ask or {}:
               if gate_matches(gate, resolved, opt_cands) → return "ask"

4. For the eligible approval kinds (one or two, per `auto_approve`):
       kinds = eligible_allow_kinds(auto_approve)
       for entry in relevant:
           for kind in kinds:
               for gate in entry[kind] or {}:
                   if gate_matches(gate, resolved, opt_cands)
                       → return "allow"

5. Return nil.

eligible_allow_kinds(auto_approve):
    if auto_approve == "allow"     then return {"read_only", "safe_write"}
    if auto_approve == "read-only" then return {"read_only"}
    return {}                                     -- auto_approve == nil
```

Precedence is **deny > ask > allow**, evaluated across the *union* of all
gates from `cmd_entry` and `wild_entry`. A deny gate on the `cmd_entry`
vetoes an allow gate on the `wild_entry` for the same command — the
`find` / `sort` corpus pins this. A `*` entry's allow gate fires for any
command whose own entry doesn't deny/ask first, which is how
`Bash(* --help)` migrates.

`vim.NIL`-valued entries (the user's mechanism for disabling a bundled
cmd via `Config.permissions.structured`) are treated as missing — the
filter in step 2 drops them.

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
if next(ctx.structured_entries) ~= nil then
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

The Phase 1a alias:

```lua
--- @alias agentic.utils.PermissionRules.WalkCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[] }
```

Extended for Phase 1b (cmd-keyed schema):

```lua
--- @alias agentic.utils.PermissionRules.WalkCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, auto_approve: agentic.PermAutoApprove }
```

Both new fields are required (no `?`). The matcher reads `auto_approve` to
select the eligible approval kinds; passing `nil` is meaningful (rejects
all allow gates). Reading from `Config.permissions.auto_approve` inside
the walker would re-introduce a `require("agentic.config")` round-trip per
leaf — better to pass it once at `should_auto_approve`'s callsite,
alongside the entries table.

`should_auto_approve` constructs the ctx:

```lua
return walk(root, command, {
    allow = allow,
    deny = M.get_deny_patterns(),
    ask = M.get_ask_patterns(),
    structured_entries = M.get_structured_entries(),
    auto_approve = Config.permissions.auto_approve,
})
```

`M.get_structured_entries()` returns the cmd-keyed table merged from the
bundled `permissions.json` plus any `Config.permissions.structured` user
additions via `vim.tbl_deep_extend("force", bundled, user)`. The accessor
returns an empty table (`{}`) when bundled defaults are disabled and no
user entries exist, in which case the composition site's
`next(ctx.structured_entries) ~= nil` guard skips the matcher entirely —
no-op for users who haven't opted in.

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
entries across `read_only`/`safe_write`/`deny`/`ask`) to the cmd-keyed
structured form. The implementation file `lua/agentic/permissions.json` is
the source of truth for the final shipped content; the example below is a
representative slice showing every shape that appears.

Conversion principles applied uniformly:

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
- `read_only` and `safe_write` are the JSON kind names (no separate
  `category` field). `auto_approve` selects which kinds count as approval.
- `deny`/`ask` glob entries fold into the same cmd entry's kind-array,
  keeping each command's rules in one place.
- The `pwd*` typo (matches `pwdwhatever`) is dropped; `pwd` plus `pwd *`
  collapse to a single bare-command entry.
- Multiple bundled glob entries that share a `cmd` all consolidate under
  one cmd key. This is one of the larger collapses (every `git
  <subcommand>` glob becomes a positional gate under `git.read_only`).

Representative example — the patterns that appear across the migration:

```jsonc
{
  // bare allow — `Bash(ls)` / `Bash(ls *)` / `Bash(xargs ls *)` collapse here
  "ls":   { "read_only": [{}] },
  "tree": { "read_only": [{}] },

  // bare safe_write — `Bash(mlr *)` lands as a safe_write allow plus deny
  "mlr":  {
    "safe_write": [{}],
    "deny":       [{ "options": ["I", "in-place"] }]
  },

  // positional allow — `Bash(pdftotext *.pdf -)`
  "pdftotext": { "read_only": [{ "positionals": ["*.pdf", "-"] }] },

  // option-only deny — `Bash(find *) + Bash(find * -exec *)/...`
  "find": {
    "read_only": [{}],
    "deny":      [{ "options": ["exec", "execdir", "okdir", "delete", "ok"] }]
  },

  // option deny + long-name variant — sed allow + -i deny with --in-place
  "sed": {
    "read_only": [{}],
    "deny":      [{ "options": ["i", "in-place"] }]
  },

  // option ask — yq allow + -i ask
  "yq": {
    "read_only": [{}],
    "ask":       [{ "options": ["i", "in-place"] }]
  },

  // subcommand-positional + option-ask — gh api with destructive flags
  "gh": {
    "read_only": [{ "positionals": ["api"] }],
    "ask":       [{ "positionals": ["api"],
                    "options":     ["X", "method", "f", "F", "input"] }]
  },

  // multiple read_only positionals (eleven git subcommand globs collapse)
  "git": {
    "read_only": [
      { "positionals": ["diff"] },
      { "positionals": ["log"] },
      { "positionals": ["show"] },
      { "positionals": ["status"] },
      { "positionals": ["config", "--get", "*"] }
    ],
    "ask": [
      { "positionals": ["push"] },
      { "positionals": ["reset"] },
      { "positionals": ["branch"],
        "options":     ["d", "D", "m", "M", "c", "C",
                        "delete", "move", "copy"] }
    ]
  },

  // mixed read_only + safe_write under one cmd
  "typst": {
    "read_only":  [{ "positionals": ["query"] }],
    "safe_write": [{}]
  },

  // cluster-bypass closure — short-letter allow paired with an ask on every
  // destructive short letter that could share the cluster (see § Cluster
  // expansion algorithm). Required wherever the allow uses short letters.
  "pacman": {
    "read_only": [{ "options": ["Q", "Si", "Ss"] }],
    "ask":       [{ "options": ["R", "U", "D", "F", "T"] }]
  },

  // bare ask — `Bash(rm *)`
  "rm": { "ask": [{}] },

  // wildcard entry — universal --help/--version + `list*` first-positional
  "*": {
    "read_only": [
      { "options": ["help", "version"] },
      { "positionals": ["list*"] }
    ]
  }
}
```

The full migrated file lives at `lua/agentic/permissions.json`; the
chunk-7 implementation produces it from the audit notes below.

#### Migration notes

**Collapses** (groups of glob entries → single structured cmd entry):

1. `Bash(git diff)`, `Bash(git diff *)`, `Bash(git *diff*)` → one
   `positionals: ["diff"]` gate under `git.read_only`. Same shape for
   `log`, `show`, `status`, `remote`, `tag`, `ls-files`, `ls-tree`,
   `rev-parse` — eleven git subcommand globs collapse to one gate each
   under a single `git` cmd entry.
2. `Bash(git -C * rev-parse *)` and `Bash(git -C * remote)`/`Bash(git -C *
   remote -v)` fold into the unprefixed gates — the option walker skips
   `-C <path>` structurally so the positional list resolves the same way.
3. `Bash(pwd)`, `Bash(pwd *)`, `Bash(pwd*)` → one entry. The `pwd*` typo
   (matches `pwdwhatever`) is dropped.
4. `Bash(branch --list*)` plus `Bash(branch)`/`Bash(branch *)` plus
   `Bash(branch -d *)`/`-D`/`-m`/`-M`/`-c`/`-C`/`--delete`/`--move`/`--copy`
   collapse to one `read_only` gate (positional `branch`) plus one `ask`
   gate (positional `branch` + the destructive options).
5. `Bash(find *)` allow + four `find` deny globs (`-exec`, `-delete*`,
   `-ok *`, `-okdir *`) plus the ask-side `-execdir *` collapse into a
   single `find` cmd entry: `read_only: [{}]` + `deny: [{options: [...]}]`.
6. `Bash(fd *)` + four `fd` deny globs (`-x *`, `-X *`, `--exec *`,
   `--exec-batch *`) collapse the same way.
7. `Bash(curl *)` + four existing curl denies + the five **new** denies
   (`-K`, `-T`, `-D`, `--output-dir`, `--trace-ascii`) collapse into one
   `curl` cmd entry with a single `deny[0].options` array.
8. `Bash(yq *)` + `Bash(yq -i*)` + `Bash(yq * -i*)` → one entry with
   `read_only: [{}]` + `ask: [{options: ["i", "in-place"]}]`.
9. `Bash(date)`, `Bash(date *)` + `Bash(date -s*)` + `Bash(date --set*)`
   → one entry with `read_only: [{}]` + `deny: [{options: ["s", "set"]}]`.
10. `Bash(* --help)` + `Bash(* --version)` → single `"*"` cmd entry with
    both option names in one `read_only` gate.

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

- `sort` — `deny: [{options: ["o", "output"]}]`. Catches `-o`, `-uo`,
  `-oFILE`, `--output=x`, `--out=x`. No current entry.
- `tee` — **dropped entirely**. The current JSON had `Bash(tee *)` under
  `safe_write`. `tee` always writes, so it should not auto-approve.
  No-entry → falls through to a permission prompt, which is the correct
  default. Users who genuinely want auto-approval (e.g. piping to a
  per-project log) add their own entry to `Config.permissions.structured`
  (cmd-keyed override; see § Structured schema). Deliberate behaviour
  change vs. the previous auto-approval at `auto_approve = "allow"`;
  flag in the PR description.
- `curl` — added `-K`/`--config`, `-T`/`--upload-file`,
  `-D`/`--dump-header`, `--output-dir`, `--trace-ascii` (in addition to
  the already-converted `-o`/`-O`/`--output`/`--remote-name`). Also add
  `--remote-name-all` (variant of `--remote-name`).
- `http` (httpie) — new entry with `deny: [{options: ["d", "download",
  "o", "output"]}]`. Current JSON had only `Bash(http *)` allow.

**Missing long-form variants** (asymmetric prefix matching catches the
canonical name + GNU abbreviations but NOT longer-suffix variants — see
§ Option matching rule):

- `ruff` — add `fix-only` (and `fix-all` if present in target ruff
  version) alongside `fix`/`unsafe-fixes` in the deny gate. Rule `fix`
  does not catch `--fix-only` under the asymmetric prefix rule.
- `sed` — add `in-place` alongside `i` in the deny gate. Same reason.
- `mlr` — add `in-place` alongside `I` in the deny gate. Same reason.
- `curl` — `remote-name-all` is a real variant; not caught by rule
  `remote-name` under asymmetric prefix.

**Cluster-bypass closure rules** (every allow-options entry with short
letters needs a matching ask gate on the destructive letters of the
same command — see § Cluster expansion algorithm):

- `pacman` — `read_only: [{options: ["Q", "Si", "Ss"]}]` needs
  `ask: [{options: ["R", "U", "D", "F", "T"]}]`. Pre-migration
  `pacman -QR foo` was approved by the glob `Bash(pacman -Q*)`; after
  this rule it prompts. `S` deliberately excluded because `-Si`/`-Ss`
  are legitimate read operations.
- `luac` — `read_only: [{options: ["l"]}]` needs `ask: [{options: ["o"]}]`.
  `luac -lo evil` writes a bytecode file under cluster expansion.
- `zsh` — `safe_write: [{options: ["n"]}]` needs
  `ask: [{options: ["c", "i", "s", "f"]}]`. `zsh -nc 'rm'` runs arbitrary
  shell when `n` is allow-listed. Pre-migration: `Bash(zsh -n *)` glob
  required literal `-n ` (space) — `-nc` did NOT match. Regression closed
  by the new ask gate.

**Audit findings**:

- `Bash(awk *system*)` deny converts to `awk.deny: [{positionals: ["*system*"]}]`.
  Parser-independent backstop — sound regardless of whether the zsh
  injection query populates awk's subtree. The script body must reach
  the matcher as positional[1] for the deny to fire; `awk -f script.awk`
  (script body in a file) is opaque to both pre and post migration.
  Two ask entries `Bash(awk * > *)` and `Bash(awk *>*)` are **dropped**
  because redirects are classified structurally by the walker
  (`file_redirect` to a non-`/dev/null` target bails) — redundant after
  Phase 1a.
- `Bash(sed *)` allow + `Bash(sed -i*)` / `Bash(sed * -i*)` deny convert
  cleanly. § Remaining residuals documents that `sed e/s///e/w/W` still
  escape this layer — accepted limitation.
- `Bash(stylua * --replace*)` — `--replace` is the actual long flag;
  folded into `stylua.deny[0].options: ["replace"]`.
- `Bash(branch *--delete *)` etc.: the leading `*` is consuming
  arg-taking-global-like noise (`git branch -r --delete foo`). The
  option walker drops the leading short option (`-r`); the destructive
  flag is now in `git.ask[].options`.
- `Bash(env *)` survives unchanged as a known wrapper-command escape —
  explicitly flagged in `notes/perm-wrapper-command-auto-approve.md`,
  out of scope for Phase 1b. Same out-of-scope deferral applies to other
  transparent wrappers (`time`, `xargs`, `nohup`, `sudo`, `nice`,
  `stdbuf`): Phase 1b doesn't add wrapper-transparency, but it also
  doesn't make these worse — `time grep foo` does not auto-approve today
  and still won't after migration. The wrapper-transparency plan is
  responsible for letting these prefixes pass through to the inner
  command's rules.
- `Bash(* list*)` becomes `"*".read_only: [{positionals: ["list*"]}]`.
  The trailing `*` is a real glob on the first positional (covers
  `list-pods`, `list-buckets`, etc.) — preserved. Deliberate tightening
  vs. pre-migration: `kubectl get foo list-pods` no longer matches the
  `list*` allow (positional[1] = `get`, not `list-pods`). See § Q4
  decision (order-dependent positional matching).
- `Bash(pacman -Q*)`, `-Si *`, `-Ss *`: pacman's short-form action flags
  fold into `read_only[0].options: ["Q", "Si", "Ss"]`. Cluster expansion
  makes `-Q` (letter) and `-Si`/`-Ss` (long names) both candidates. See
  the cluster-bypass closure rule above for the matching ask gate.
- Duplicate-shape pairs `Bash(systemctl list-*)` plus `Bash(* list*)`:
  the `"*"` entry already covers it but the `systemctl` entry is kept
  for clarity (cheap, non-overlapping with denies). Not strictly
  redundant — survives.
- `Bash(awk * > *)`, `Bash(awk *>*)` — dropped; walker `file_redirect`
  classification handles redirects structurally.

**Entry count**: 396 glob entries → roughly 60 cmd keys (each carrying
multiple gates under its kind-arrays). The collapse is much larger than
the flat-array form because subcommand globs (eleven git, twenty
hyprctl, thirty-one gh, etc.) fold under one cmd key each. Every entry
in the current `permissions.json` is either present in the new file
(possibly merged), explicitly listed as dropped (`tee`, pipelines,
`pwd*` typo, `awk *>*` ask entries), or replaced by a
structurally-equivalent new entry. The chunk-7 implementation MUST
verify the cmd-key count and run the faithfulness sweep tests (see
§ Phase 1b tests) before merging.

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
- `mlr` write verbs reached past a `then` chain (`mlr cat then tee out`) or
  inside a `put`/`filter` DSL string (`mlr put 'tee > "x", $*'`). `mlr` is
  `read_only` with `ask` carve-outs on the `split`/`tee` verbs and a `deny`
  on `-I`/`--in-place`, but positional matching is index-based — it sees only
  the first verb, not verbs after `then`, and the DSL body is one opaque
  positional. Both auto-approve at `auto_approve = "read-only"`. Same tier as
  `awk` `system()` inside an opaque script body: a parser-independent backstop
  would need DSL injection descent (§ Injected-sublanguage descent),
  best-effort only.

### Phase 1b tests

**Cluster-soundness and migration-positive cases:**

- `sort -uo out` (short cluster), `sort --out=x` (GNU abbreviation),
  `sort -oFILE` (glued arg) → all deny via
  `sort.deny: [{options: ["o", "output"]}]`.
- `git -C diff push` → option walker consumes `-C diff`, positionals
  resolve to `["push"]`, not `["diff", "push"]` → no `git.read_only`
  positional-`diff` gate matches; falls through.
- `git -C path config --get foo` → positionals resolve to
  `["config", "--get", "foo"]` matching the `["config", "--get", "*"]`
  read_only gate → allow.
- `pdftotext *.pdf -` → approve via positional-glob read_only.
- `tee out` → prompt (no entry; users opt-in via
  `Config.permissions.structured`).
- `curl -K config.txt`, `curl --upload-file f url` → deny.
- `ls --help`, `ls --version` → approve via the `"*"` read_only gate.
- `mlr -I foo` at any `auto_approve` value → deny (deny wins
  unconditionally).
- `mlr foo` at `auto_approve = "read-only"` → no approval (mlr's
  read_only kind is empty; safe_write is filtered out by auto_approve).
- `mlr foo` at `auto_approve = "allow"` → approve (safe_write kind is
  eligible).

**Cluster-bypass closure cases** (the new ask gates close these holes):

- `pacman -QR foo` → ask (R is in pacman.ask options; precedence
  beats the read_only match on Q).
- `pacman -Q kitty` → approve (only Q in cluster; no destructive letter).
- `luac -lo evil.luac foo.lua` → ask (o in luac.ask).
- `luac -l foo.lua` → approve.
- `zsh -nc 'rm'` → ask (c in zsh.ask).
- `zsh -n script.zsh` → approve at `auto_approve = "allow"`.

**Walker `literal_token` strict/lenient cases:**

- `sort "-o" out` → deny (string quote-stripped, `-o` candidate fires).
- `sort -ex"e"c out` (literal concatenation in option position) →
  joined literal `-exec`; `find.deny` matches in the find variant.
- `sort -ex"$x"c out` (substitution inside concatenation) → bail.
- `ls "$f"` (bare expansion at top-level) → approve (literal_token
  returns raw source for expansion-bearing string; no option candidate).
- `gr"e"p foo file` (literal concat in command-name position) →
  resolves to command name `grep`, allow via `grep.read_only`.

**Override mechanism (`Config.permissions.structured`):**

- User adds `tee = { safe_write = { {} } }` → `tee out` now approves
  at `auto_approve = "allow"`.
- User sets `rm = vim.NIL` → `rm foo.txt` no longer prompts (the
  bundled `rm.ask` is removed).
- User overrides `pacman.ask = {}` → `pacman -R foo` approves (closure
  rule disabled).
- User adds a new cmd key (e.g. `kubectl = { read_only = [{}] }`) →
  `kubectl get pods` approves.

**Migration faithfulness sweep** (judgment-based — some cases
intentionally diverge from pre-migration behaviour, see § Migration
notes for the deliberate behaviour shifts):

A focused corpus of ~30-50 real command shapes (cmd + flags +
positionals) drawn from recent agent transcripts and the migration
notes. Each case asserts the new decision against the migrated JSON.
Deliberate behaviour shifts (tee → prompt, pacman -QR → ask, zsh -nc
→ ask, `kubectl get foo list-pods` → prompt) are listed explicitly
and the test asserts the new (correct) behaviour, not the
pre-migration glob behaviour.

### Work breakdown

Phase 1b is large enough to split across multiple subagents. Two passes:
**plan-fleshing** (already complete — see § Status) then **implementation**
(code lands per the chunks below). Tests are written before the matcher
code is reworked — the test file is committed in a failing state and the
diff that re-shapes the matcher turns the tests green.

The starting point is the `phase-1b` branch's existing commit (`WIP:
Phase 1b structured matcher (pre-schema-refactor)`) which has the
flat-array form. The implementation chunks below refactor that to the
cmd-keyed schema per § Structured schema.

#### Implementation pass (sequential)

1. **Test corpus refactor.** Rewrite
   `lua/agentic/utils/permission_structured.test.lua` so every
   `decide_leaf(entries, parsed, auto_approve)` call passes a cmd-keyed
   `entries` table instead of a flat array. Gate shape unchanged. Test
   cases new to this pass:
   - cmd-keyed lookup: `entries[cmd_name]` and `entries["*"]` resolution
   - eligible-kinds selection per `auto_approve`
   - `vim.NIL`-valued entry treated as missing
   - explicit removal of any test asserting the old `category` field

2. **Module refactor.** Rewrite `permission_structured.lua`:
   - drop `category`, `allow_category_ok`, `agentic.PermCategory`
   - new types per § Matcher API spec (`StructuredCmdEntry`,
     `StructuredEntries`, `PermKind`)
   - `decide_leaf` reshaped to dict lookup + `eligible_allow_kinds`
   - walker integration in `permission_rules.lua` updates the
     `WalkCtx.structured_entries` type from list to table

3. **JSON migration.** Replace `lua/agentic/permissions.json` with the
   cmd-keyed form per § Migration. Includes:
   - all collapses listed in § Migration notes
   - the missing-long-form-variants audit (`ruff fix-only`,
     `sed in-place`, `mlr in-place`, `curl remote-name-all`)
   - the cluster-bypass closure rules (`pacman` ask, `luac` ask,
     `zsh` ask)
   - `tee` drop
   Verify with a `jq 'keys | length'` count and the faithfulness sweep
   tests.

4. **Loader + override mechanism.** Update
   `M.get_structured_entries()` in `permission_rules.lua`:
   - reads the new cmd-keyed JSON
   - merges `Config.permissions.structured` via
     `vim.tbl_deep_extend("force", bundled, user)`
   - strips `vim.NIL`-valued entries before returning to the matcher
   - cache invalidation per the existing mtime / table-ref discipline

5. **Walker integration verification.** Re-run the live-permissions
   describe blocks in `permission_rules.test.lua`. All existing Phase 1a
   + initial Phase 1b tests must stay green. The walker itself does
   not change — only the `ctx.structured_entries` type.

6. **Docs.** Update `CLAUDE.md` § "Compound Bash commands",
   `lua/agentic/acp/AGENTS.md` § "Compound Bash commands", the README
   permissions section, and add a `doc/agentic.txt` § structured
   permissions block with the override examples (per § Structured
   schema).

Chunks 1–6 are sequential — each consumes the previous chunk's output.

Phase 2 (assignment-position substitution + loops) is on the
`phase-2-substitution-loops` branch — see
[notes/perm-substitution-loops-plan.md](perm-substitution-loops-plan.md).
After Phase 1b lands on `main`, that branch must be rebased onto `main`
to pick up the new schema; the Phase 2 walker code itself is
schema-agnostic (it goes through `walk_command` which calls
`decide_leaf` opaquely).

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
  detection skipping arg-taking globals). Phase 1b and Phase 2 land on
  separate branches (see § Status) so each gets focused review.
- **Migration faithfulness** — the full migration of ~250 cmd entries
  has gaps in unit test coverage. The faithfulness sweep in § Phase 1b
  tests is the gating signal before merging. Deliberate behaviour
  shifts (tee → prompt, pacman -QR → ask, zsh -nc → ask,
  `kubectl get foo list-pods` → prompt) are listed explicitly and must
  appear in PR description.

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
