# Plan: one structured classification and one leaf front per command leaf
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/utils/permission_structured.lua` — `decide_leaf`,
  `classify_leaf`, `agentic.PermClassification`, `eligible_allow_kinds`,
  `tier_admits`,
  `deny_leaf`, `allow_entries`, `relevant_entries`
- `lua/agentic/utils/permission_rules.lua` — `walk_command`,
  `classifies_read_only`, `walk_function_definition`, `command_known_safe`,
  `structured_reason`, `command_is_denied`, `extract_args`,
  `command_leaf_name`, `script_operand`, `refuses_builtin`, `leaf_text`,
  `strip_command_path`
- `lua/agentic/utils/permission_structured.test.lua` — the header API
  comment and every describe that calls `decide_leaf` (83 calls, from
  "universal allow reading (via decide_leaf)" through "gate conditions"),
  "classify_leaf", "deny_leaf"
- `lua/agentic/utils/permission_rules.test.lua` (walk, tally, reject cases,
  "decision sources")
- `lua/agentic/ui/permission_manager.test.lua` (approval causes)
- `notes/FIX-deny-gate-flag-cap.md` (names `decide_leaf`/`classify_leaf`)
- Skills: `permissions` (§ Shell command parsing, `references/parsing.md`),
  `implement`, `neovim`

## Background
`classify_leaf` was added beside `decide_leaf` for the prompt highlight
(f238a5e). The two build the same contexts and run the same deny, ask and
allow gate loops; `decide_leaf` only stops at the first match and applies
`tier`. The approve walk then calls both on one leaf: `walk_command` runs
`decide_leaf`, and for any source but `read_only` it runs
`classifies_read_only` → `classify_leaf` again for the taint (dfdf7d9). de9b3b3
added `tier_admits(tier, c)`, a third piece of tier logic, so the
tally can say `tier`.

The code written for all three needs: one classifier per leaf; the tier
decision a pure function of the classification. The walk classifies once and
reads both its decision and its taint from that.

`structured_reason`'s second `classify_leaf` call is not a copy: it asks a
different question (the leaf with every dynamic word read as written) and
stays. `deny_leaf` stays too: its concrete-only matching is a different
question by design (its docstring).

The three walkers (`walk_command`, `command_known_safe`, `command_is_denied`)
open with the same lines: `extract_args`, `ShellParse.command_name`,
`strip_command_path`, `leaf_text`; the first two also share the
`script_operand` + `refuses_builtin` + `ctx.shadowed` refusal. Their control
flow after that differs on purpose (first bail, find all, first concrete
deny), so only the front is shared.

`decide_leaf`'s precedence "own entry over `*`" exists only for the footer
word (6e03546). A classification merges entries, so `read_only` wins over
`safe_write`. The bundled `*` entry holds only `--help`/`--version`, so the
visible change is a footer saying `read-only` for such a leaf where its own
entry also matched `safe_write`. The leaf's taint already reads the merged
category. A call to a function does not: `walk_command` taints it when the
body's sources hold anything but `read_only`, and those sources come from
the allow kind. Such a body leaf now gives `read_only`, so the call no
longer taints.

## Changes
### `permission_structured.lua`
- `classify_leaf(entries, parsed)` stays the one classifier; docstring loses
  the comparison with `decide_leaf`.
- `decide_leaf` and `tier_admits` go. New:
  ```lua
  --- The allow kind `tier` admits among a classification's allow matches,
  --- read_only first; nil when it has a deny or ask match, or none admitted.
  --- @param c agentic.PermClassification
  --- @param tier agentic.PermAutoApproveTier
  --- @return agentic.PermAllowKind|nil kind
  function M.allow_kind(c, tier)
  ```
  Built on `eligible_allow_kinds`. Callers test `c.deny or c.ask` for the
  deny/ask outcome themselves, as both already do.
- Comments that name `decide_leaf` (the `agentic.StructuredEntries` alias,
  the `deny_leaf` docstring, the `vim.NIL` comment in `get_entries`) name
  `classify_leaf` instead.

### `permission_rules.lua`
- New local, replacing the copied front of the three walkers:
  ```lua
  --- @class agentic.utils.PermissionRules.Leaf
  --- @field name string command word as written
  --- @field cmd_name string `name` with a system bin dir stripped
  --- @field args string[]
  --- @field arg_nodes TSNode[]
  --- @field args_dynamic boolean[]
  --- @field text string `leaf_text(name, args)`

  --- A `command` node's name and delivered words, or why they cannot be had.
  --- @param node TSNode
  --- @param src string
  --- @param ctx any threaded to `inner_check` (see `extract_args`)
  --- @param known table<string, string>|nil
  --- @param inner_check fun(subst: TSNode, src: string, ctx: any): boolean
  --- @return agentic.utils.PermissionRules.Leaf|nil leaf
  --- @return agentic.utils.PermissionRules.Reason|nil reason `structure` when the words do not extract, `dynamic` when the name is not static; nil with a leaf
  local function command_leaf(node, src, ctx, known, inner_check)
  ```
  It keeps `name` (as written, for `ctx.shadowed`, `funcs` and the leaf
  text) and takes `cmd_name` from `command_leaf_name`, which stays shared
  with `collect_bindings`. And:
  ```lua
  --- Whether a leaf must prompt whatever the rules say: `refuses_builtin`
  --- (a code-taking builtin, with a resolving script lifting `source`/`.`;
  --- an arithmetic read; a dynamic or unsafe `printf -v`/`read` target), or
  --- a call to a name in `shadowed`.
  --- @param leaf agentic.utils.PermissionRules.Leaf
  --- @param src string
  --- @param shadowed agentic.utils.PermissionRules.Shadowed
  --- @return boolean
  local function refuses_leaf(leaf, src, shadowed)
  ```
  `extract_args` keeps its signature: `collect_bindings` needs only args.
  Its forward declaration's `@type` lists a fourth return it does not have;
  drop it.
- An action host's rewrite (`args, args_dynamic = actions.args, …`) rebinds
  locals taken from the leaf; `leaf` itself is not mutated, so `leaf.text`
  keeps the words as written for the glob matchers, as today.
- `walk_command`: `command_leaf` + `refuses_leaf`; one `classify_leaf` when
  entries exist; `c.deny or c.ask` → false; else `allow_kind(c, tier)`; the
  taint reads `c.read_only` (no `c` → tainted). `classifies_read_only` goes.
- `command_known_safe`: `command_leaf` (its two early reasons come from it)
  + `refuses_leaf`; the tier branch tests `allow_kind(c, ctx.tier) == nil`.
- `command_is_denied`: `command_leaf` with the pass-through `inner_check`;
  nil on a reason, as now.

### Callers to audit
- `decide_leaf`: `walk_command` only (plus tests).
- `classify_leaf`: `classifies_read_only`, `command_known_safe`,
  `structured_reason`.
- `tier_admits`: `command_known_safe`.
- `command_leaf_name`: `collect_bindings`, and `command_leaf`.
- `extract_args`: the three walkers, `collect_bindings`.

### Tests
Written first:
- `permission_structured.test.lua`: `allow_kind` over hand-built
  classifications: deny or ask with every allow flag set → nil; read_only at
  `"read_only"` and `"safe_write"`; safe_write only at `"read_only"` → nil;
  both flags at `"safe_write"` → `"read_only"`; any allow at nil tier → nil.
- `permission_rules.test.lua` "decision sources": a leaf matching its own
  `safe_write` gate and a `*` `read_only` gate gives sources
  `{ read_only = true }`.
- `permission_rules.test.lua`, the taint: with the same two entries,
  `f() { X --help; }; f; <leaf that reads code>` (a leaf whose read
  `file_reader`/`may_run_config_code` gates on the taint) reads the code as it
  would with no call before it.

Then:
- The `decide_leaf` describes call a local helper
  `decide(entries, parsed, tier)` that returns `"deny"`/`"ask"` from the
  classification, else `"allow"` with `allow_kind`; the assertions stay,
  except "prefers the command's own entry over the wildcard", which becomes
  "reports read_only when any entry's read_only gate matches" and expects
  `"read_only"`.
- The rest of `permission_rules.test.lua` passes unchanged.

## Expected outcome
- Each leaf is classified once per pass of a walk (a re-walk by
  `walk_until_shadowed_settles` classifies again; `structured_reason` still
  classifies a dynamic leaf a second time, read as written).
- Prompt, reject and tally results are unchanged. For a leaf matching both
  its own `safe_write` gate and a `*` `read_only` gate: its footer shows
  `read-only`, and a call to a function whose body runs it no longer sets
  the walk's taint.

## Non-goals
- One parse shared by the reject pass, the approve walk and the tally. A
  parse is in-process and cheap, and sharing it changes three public
  signatures and about 350 test calls.
- Merging the three walkers.
- Matcher changes (`FIX-deny-gate-flag-cap.md`,
  `BUG-reject-pass-value-words.md`, `BUG-tar-bundle-ask.md`,
  `BUG-matcher-depth-overflow.md`). They edit gate matching under
  `classify_leaf`/`deny_leaf`, not this layer; after this lands, read their
  `decide_leaf` mentions as `classify_leaf` + `allow_kind`.

## Open questions
None.
